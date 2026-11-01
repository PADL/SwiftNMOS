//
// Copyright (c) 2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import FlyingFox
import Foundation
import NMOS

/// The IS-05 Connection API of a device, as a controller uses it.
public struct NMOSConnectionClient: Sendable {
  private static let controlType = "urn:x-nmos:control:sr-ctrl/"
  private static let sdpType = "application/sdp"

  private let apiURL: URL
  private let http: any NMOSHTTPClient

  /// `apiURL` ends with the API's version, as a device's control does.
  public init(apiURL: URL, http: any NMOSHTTPClient = NMOSFlyingFoxHTTPClient()) {
    self.apiURL = apiURL
    self.http = http
  }

  /// The newest Connection API a device lists.
  public init?(device: NMOSDeviceResource, http: any NMOSHTTPClient = NMOSFlyingFoxHTTPClient()) {
    let control = device.controls
      .filter { $0.type.hasPrefix(Self.controlType) }
      .max { $0.type.compare($1.type, options: .numeric) == .orderedAscending }
    guard let href = control?.href, let apiURL = URL(string: href) else { return nil }
    self.init(apiURL: apiURL, http: http)
  }

  private func receiver(_ id: NMOSID) -> URL {
    apiURL.appending(path: "single/receivers/\(id)")
  }

  /// A sender's SDP. Following a redirect, as an API may send this to the sender's manifest.
  public func transportFile(sender id: NMOSID) async throws -> String {
    try await text(at: apiURL.appending(path: "single/senders/\(id)/transportfile"))
  }

  /// The SDP at a sender's `manifest_href`.
  public func text(at url: URL) async throws -> String {
    var response = try await http.send(.GET, url, body: nil)
    if (300...399).contains(response.status), let location = response.headers["location"],
       let target = URL(string: location, relativeTo: url)
    {
      response = try await http.send(.GET, target.absoluteURL, body: nil)
    }
    guard response.status == 200, let text = String(data: response.body, encoding: .utf8) else {
      throw NMOSClientError.status(response.status, url.absoluteString)
    }
    return text
  }

  private func stage(_ id: NMOSID, _ request: NMOSJSONValue) async throws {
    let url = receiver(id).appending(path: "staged")
    let response = try await http.send(.PATCH, url, body: JSONEncoder().encode(request))
    guard (200...202).contains(response.status) else {
      let reason = String(data: response.body, encoding: .utf8) ?? ""
      throw NMOSClientError.status(response.status, reason)
    }
  }

  private static let activateNow: NMOSJSONValue = [
    "mode": .string(NMOSActivationMode.immediate.rawValue),
    "requested_time": .null,
  ]

  /// Has a receiver take `sender`, described by `sdp`, now.
  public func connect(receiver id: NMOSID, sender: NMOSID, sdp: String) async throws {
    try await stage(id, [
      "sender_id": .string(sender.description),
      "master_enable": .bool(true),
      "activation": Self.activateNow,
      "transport_file": ["data": .string(sdp), "type": .string(Self.sdpType)],
    ])
  }

  /// Has a receiver stop receiving, now.
  public func disconnect(receiver id: NMOSID) async throws {
    try await stage(id, [
      "sender_id": .null,
      "master_enable": .bool(false),
      "activation": Self.activateNow,
      "transport_file": ["data": .null, "type": .null],
    ])
  }
}
