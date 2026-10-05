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

/// The IS-04 Node API, which serves the node's resources as the resource store holds them.
enum NMOSNodeAPI {
  static let version = NMOSAPIVersion.v1_3

  static func register(on router: NMOSRouter, store: NMOSResourceStore) async {
    let base = "node/\(version)"

    await router.add(.GET, "\(base)/self") { _ in
      guard let node = await store.node else {
        throw NMOSHTTPError(.serviceUnavailable, "The node has not been described yet")
      }
      return try .nmos(json: node)
    }

    for kind in NMOSResourceKind.registrationOrder where kind != .node {
      let placeholder = "\(kind.rawValue)Id"
      await router.add(.GET, "\(base)/\(kind.collection)") { _ in
        try await .nmos(json: store.resources(kind))
      }
      await router.add(.GET, "\(base)/\(kind.collection)/{\(placeholder)}") { request in
        guard let resource = try await store.resource(kind, id: request.id(placeholder)) else {
          throw NMOSHTTPError.notFound()
        }
        return try .nmos(json: resource)
      }
    }

    // superseded by the Connection API; from v1.3 a node may decline it, and this one does
    await router.add(.PUT, "\(base)/receivers/{receiverId}/target") { request in
      guard try await store.resource(.receiver, id: request.id("receiverId")) != nil else {
        throw NMOSHTTPError.notFound()
      }
      throw NMOSHTTPError.notImplemented("Connect receivers through the Connection API (IS-05)")
    }
  }
}
