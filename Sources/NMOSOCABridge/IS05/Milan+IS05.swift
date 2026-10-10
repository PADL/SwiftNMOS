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

/// AVB streams of a Milan entity (AES70-22). A listener stream is bound to a talker
/// stream, which a talker's entity ID and stream index name, so those two are the
/// transport parameters: of a receiver the talker it is bound to, of a sender its own.
extension NMOSOcaMilanAdaptation {
  private static let entityID = "entity_id"
  private static let streamIndex = "stream_index"

  // MARK: Reading

  /// The application and its endpoints say which are claimed; a listener's binding is
  /// its session, found through the application's agents.
  public var observedProperties: NMOSOcaObservedProperties {
    .of(SwiftOCADevice.OcaMediaTransportApplication.self, [
      .init(defLevel: 2, propertyIndex: 4), // adaptationIdentifier
      .init(defLevel: 3, propertyIndex: 10), // endpoints
      .init(defLevel: 3, propertyIndex: 13), // transportSessionControlAgentONos
    ]) + .of(SwiftOCADevice.OcaMediaTransportSessionAgent.self, [.init(defLevel: 3, propertyIndex: 2)])
  }

  /// The session agent holding the session for an input endpoint. AES70-22 gives each
  /// input endpoint one session, with the endpoint's ID.
  private func sessionAgent(of endpoint: NMOSOcaEndpoint) async -> SwiftOCADevice.OcaMediaTransportSessionAgent? {
    for oNo in endpoint.application.transportSessionControlAgentONos {
      guard let agent: SwiftOCADevice.OcaMediaTransportSessionAgent =
        await endpoint.application.deviceDelegate?.resolve(objectNumber: oNo) else { continue }
      if (try? agent.session(endpoint.endpoint.idInternal)) != nil { return agent }
    }
    return nil
  }

  private static func parameters(_ stream: MilanMediaStreamEndpointIDExternal?) -> NMOSTransportParameters {
    guard let stream, stream != .unbound else { return [entityID: .null, streamIndex: .null] }
    // sixteen hexadecimal digits, as an entity ID is conventionally written
    let hex = String(stream.entityID, radix: 16)
    return [
      entityID: .string(String(repeating: "0", count: 16 - hex.count) + hex),
      streamIndex: .integer(Int64(stream.streamIndex)),
    ]
  }

  private static func stream(_ parameters: NMOSTransportParameters) throws -> MilanMediaStreamEndpointIDExternal {
    guard let text = parameters[entityID]?.nonEmptyString,
          let entity = UInt64(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16), entity != 0,
          let index = parameters[streamIndex]?.integerValue.flatMap(UInt16.init(exactly:))
    else {
      throw NMOSConnectionError.invalid("Binding needs the talker's `entity_id` and `stream_index`")
    }
    return MilanMediaStreamEndpointIDExternal(entityID: entity, streamIndex: index)
  }

  public func active(of endpoint: NMOSOcaEndpoint) async throws -> NMOSConnectionState {
    if endpoint.isSender {
      let own = try? endpoint.endpoint.idExternal.decode(MilanMediaStreamEndpointIDExternal.self)
      return NMOSConnectionState(masterEnable: true, transportParameters: [Self.parameters(own)])
    }
    guard let session = try? await sessionAgent(of: endpoint)?.session(endpoint.endpoint.idInternal) else {
      return NMOSConnectionState(masterEnable: false, transportParameters: [Self.parameters(nil)])
    }
    let remote = try? session.connections.first?.remoteEndpointID.decode(MilanMediaStreamEndpointIDExternal.self)
    let bound = remote != nil && remote != .unbound
    return NMOSConnectionState(
      masterEnable: bound && session.streamingEnabled,
      transportParameters: [Self.parameters(remote)]
    )
  }

  public func receiverConstraints(of endpoint: NMOSOcaEndpoint) async throws -> [[String: NMOSConstraint]] {
    [[
      Self.entityID: .init(pattern: "^(0x)?[0-9a-fA-F]{1,16}$"),
      Self.streamIndex: .init(maximum: 65535, minimum: 0),
    ]]
  }

  // MARK: Activation

  public func activateReceiver(_ endpoint: NMOSOcaEndpoint, staged: NMOSConnectionState) async throws {
    guard let agent = await sessionAgent(of: endpoint) else { throw NMOSConnectionError.notFound }
    let id = endpoint.endpoint.idInternal
    do {
      guard staged.masterEnable else {
        return try await agent.resetSession(id: id, from: NMOSOcaControlController.connection)
      }
      let talker = try Self.stream(staged.transportParameters.first ?? [:])
      let connection = try agent.session(id).connections.first?.id ?? 1
      try await agent.configureConnection(
        sessionID: id, connectionID: connection, localEndpointID: id, remoteEndpointID: talker.blob,
        from: NMOSOcaControlController.connection
      )
      // binding leaves the stream waiting; an enabled receiver is one that is streaming
      try await agent.setStreamingEnabled(id: id, active: true, from: NMOSOcaControlController.connection)
    } catch {
      throw NMOSConnectionError(error)
    }
  }
}
