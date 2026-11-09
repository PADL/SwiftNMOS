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
import SwiftOCA
import SwiftOCADevice

extension NMOSOcaMilanAdaptation {
  /// A stream is named `ieee1722:<entity ID>:<unique ID>`: the entity ID as 16 lowercase
  /// hex digits, and the stream's ACMP talker or listener unique ID, which is its
  /// STREAM_OUTPUT or STREAM_INPUT index (IEEE 1722.1-2021 Clause 8.2.1).
  /// The resource kind tells a talker from a listener of the same index.
  public func nativeIdentity(of endpoint: NMOSOcaEndpoint) async -> String? {
    guard let own = try? endpoint.endpoint.idExternal.decode(MilanMediaStreamEndpointIDExternal.self)
    else { return nil }
    let application = try? endpoint.application.adaptationData.decode(MilanMediaTransportAdaptationData.self)
    let entity = own.entityID != 0 ? own.entityID : application?.entityID ?? 0
    guard entity != 0 else { return nil }
    let hex = String(entity, radix: 16)
    return "ieee1722:\(String(repeating: "0", count: 16 - hex.count) + hex):\(own.streamIndex)"
  }
}
