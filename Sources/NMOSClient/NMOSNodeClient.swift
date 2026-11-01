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

import Foundation
import NMOS

/// An IS-04 Node API, as a controller reads it where there is no registry. A resource this
/// library has no representation for, such as a video receiver, is left out rather than
/// failing what it was read with.
public struct NMOSNodeClient: Sendable {
  public static let apiVersion = "v1.3"

  /// The root of the node's HTTP server, as `http://node:8080`.
  public let baseURL: URL
  private let http: any NMOSHTTPClient

  public init(baseURL: URL, http: any NMOSHTTPClient = NMOSFlyingFoxHTTPClient()) {
    self.baseURL = baseURL
    self.http = http
  }

  private func read(_ kind: NMOSResourceKind) async throws -> Data {
    let url = baseURL.appending(path: "x-nmos/node/\(Self.apiVersion)/\(kind.collection)")
    let response = try await http.send(.GET, url, body: nil)
    guard response.status == 200 else {
      throw NMOSClientError.status(response.status, url.absoluteString)
    }
    return response.body
  }

  /// The node itself, which is `/self` rather than a collection.
  public func node() async throws -> NMOSNodeResource {
    try await JSONDecoder().decode(NMOSNodeResource.self, from: read(.node))
  }

  /// Everything of a kind the node holds. Unlike a Query API, a Node API has no pages.
  public func resources<Resource: NMOSResourceRepresentable>(
    _ type: Resource.Type = Resource.self
  ) async throws -> [Resource] {
    try await JSONDecoder().decode(
      [NMOSQueryClient.Lossy<Resource>].self,
      from: read(Resource.kind)
    ).compactMap(\.value)
  }
}
