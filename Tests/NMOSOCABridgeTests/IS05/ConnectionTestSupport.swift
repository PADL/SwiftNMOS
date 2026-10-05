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
import NMOSOCABridge
import SwiftOCA
import SwiftOCADevice
import XCTest

/// Another controller of the device, for a change a test makes as one would.
actor TestController: OcaController {
  nonisolated var flags: OcaControllerFlags { [] }

  func sendMessages(_ messages: [any Ocp1Message], type messageType: OcaMessageType) async throws {}
}

/// The Connection API over the OCA connection provider, for the applications a test
/// gives the shared device: what a controller sees of them through IS-05.
@OcaDevice
final class ConnectionStack {
  nonisolated static let ids = NMOSOcaResourceIDs(seed: "is05-tests")

  let store = NMOSResourceStore()
  let provider: NMOSOcaConnectionProvider
  let api: NMOSConnectionAPI
  let router = NMOSRouter()
  private var task: Task<Void, Never>?

  init(
    _ applications: [SwiftOCADevice.OcaMediaTransportApplication],
    adaptations: NMOSOcaAdaptations = .standard
  ) async throws {
    try await TestDevice.networkManager().networkApplications = applications
    provider = NMOSOcaConnectionProvider(adaptations: adaptations) { ConnectionStack.ids }
    api = NMOSConnectionAPI(provider: provider, store: store)
    await api.register(on: router)
    task = Task { [api] in await api.run() }
  }

  deinit { task?.cancel() }

  func id(_ application: SwiftOCADevice.OcaMediaTransportApplication, _ endpoint: OcaMediaStreamEndpointID) -> NMOSID {
    Self.ids.id(endpoint >= 1000 ? .sender : .receiver, application: application.objectNumber, endpoint: endpoint)
  }

  func send(
    _ method: HTTPMethod,
    _ path: String,
    _ body: NMOSJSONValue? = nil
  ) async throws -> (status: HTTPStatusCode, json: NMOSJSONValue?, response: HTTPResponse) {
    let request = try HTTPRequest(
      method: method, version: .http11, path: "/x-nmos/connection/v1.2/single/\(path)", query: [],
      headers: [:], body: HTTPBodySequence(data: body?.data() ?? Data())
    )
    let response = try await router.handleRequest(request)
    let data = try await response.bodyData
    let json = response.headers[.contentType] == "application/json" ? try NMOSJSONValue(data: data) : nil
    return (response.statusCode, json, response)
  }

  /// The first leg of the transport parameters at `/active` or `/staged`.
  func parameters(_ path: String) async throws -> NMOSJSONValue? {
    try await send(.GET, path).json?["transport_params"]?.arrayValue?.first
  }

  /// Polls a resource until `condition` holds of it, as a controller observing an
  /// endpoint that something else is changing would.
  func wait(
    for path: String,
    where condition: (NMOSJSONValue) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> NMOSJSONValue? {
    for _ in 0..<300 {
      if let resource = try await send(.GET, path).json, condition(resource) { return resource }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("the change did not reach \(path)", file: file, line: line)
    return nil
  }
}

extension TestDevice {
  static func role(_ name: String) -> String { "\(name)-\(UUID().uuidString)" }

  /// A network interface with the IPv4 address, and the assignment giving it to an application.
  static func interfaceAssignment(address: String) async throws -> OcaNetworkInterfaceAssignment {
    let interface = try await SwiftOCADevice.OcaNetworkInterface(
      role: role("Interface"), deviceDelegate: OcaDevice.shared
    )
    interface.currentAdaptationData = try OcaIP4NetworkSettings(
      addressAndPrefix: "\(address)/24", autoconfigMode: .none, dhcpServerAddress: "",
      defaultGatewayAddress: "", additionalGateways: [], dnsServerAddresses: [], additionalParameters: ""
    ).blob
    return OcaNetworkInterfaceAssignment(
      id: 1, networkInterfaceONo: interface.objectNumber, networkBindingParameters: OcaBlob(),
      securityKeyIdentities: [], advertisingMechanisms: []
    )
  }
}
