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

/// A Milan session agent as a device implements it: ConfigureConnection binds the
/// listener, leaving it waiting, and SetStreamingEnabled starts it.
final class TestMilanSessionAgent: SwiftOCADevice.MilanOcaMediaTransportSessionAgent {
  var bindings = [(session: OcaMediaTransportSessionID, talker: MilanMediaStreamEndpointIDExternal)]()
  var resets = [OcaMediaTransportSessionID]()

  private func remote(_ id: OcaMediaTransportSessionID) throws -> MilanMediaStreamEndpointIDExternal {
    try session(id).connections.first?.remoteEndpointID.decode(MilanMediaStreamEndpointIDExternal.self) ?? .unbound
  }

  override func configureConnection(
    sessionID: OcaMediaTransportSessionID,
    connectionID: OcaMediaTransportSessionConnectionID,
    localEndpointID: OcaMediaStreamEndpointID,
    remoteEndpointID: OcaBlob,
    from controller: any OcaController
  ) async throws {
    guard connectionID == 1, localEndpointID == sessionID else { throw Ocp1Error.status(.parameterError) }
    let talker = try remoteEndpointID.decode(MilanMediaStreamEndpointIDExternal.self)
    bindings.append((sessionID, talker))
    try update(sessionID: sessionID, remote: talker, streamingEnabled: false, localEndpointState: .ready)
  }

  override func resetSession(id: OcaMediaTransportSessionID, from controller: any OcaController) async throws {
    resets.append(id)
    try update(sessionID: id, remote: .unbound, streamingEnabled: false, localEndpointState: .notReady)
  }

  override func setStreamingEnabled(
    id: OcaMediaTransportSessionID,
    active: OcaBoolean,
    from controller: any OcaController
  ) async throws {
    try update(
      sessionID: id, remote: remote(id), streamingEnabled: active,
      localEndpointState: active ? .running : .ready
    )
  }
}

final class IEEE1722ConnectionTests: XCTestCase {
  private static let entity: OcaUint64 = 0x0011_22FF_FE33_4455

  @OcaDevice
  private func makeStack() async throws
    -> (SwiftOCADevice.OcaMediaTransportApplication, TestMilanSessionAgent, ConnectionStack)
  {
    _ = try await TestDevice.networkManager()
    let application = try await TestDevice.makeApplication("Milan")
    application.adaptationIdentifier = MilanAdaptation.identifier
    let agent = try await TestMilanSessionAgent(role: TestDevice.role("Sessions"), deviceDelegate: OcaDevice.shared)
    application.transportSessionControlAgentONos = [agent.objectNumber]

    // stream index 0 in each direction, numbered as AES70-22 numbers endpoints
    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input))
    try agent.insert(session: SwiftOCADevice.MilanOcaMediaTransportSessionAgent.makeSession(inputEndpointID: 1))
    try application.insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: 1001,
      idExternal: MilanMediaStreamEndpointIDExternal(entityID: Self.entity, streamIndex: 0).blob,
      direction: .output
    ))
    return try await (application, agent, ConnectionStack([application]))
  }

  @OcaDevice
  func testStreamsAreConnectionsOfTheIEEE1722Transport() async throws {
    let (application, _, stack) = try await makeStack()
    let receiver = "receivers/\(stack.id(application, 1))"
    let sender = "senders/\(stack.id(application, 1001))"

    let type = try await stack.send(.GET, "\(receiver)/transporttype")
    XCTAssertEqual(type.json, "urn:x-padl:transport:ieee1722")
    let unbound = try await stack.send(.GET, "\(receiver)/active")
    XCTAssertEqual(unbound.json?["master_enable"], false)
    XCTAssertEqual(unbound.json?["transport_params"], [["entity_id": .null, "stream_index": .null]])

    let talker = try await stack.send(.GET, "\(sender)/active")
    XCTAssertEqual(talker.json?["transport_params"], [["entity_id": "001122fffe334455", "stream_index": 0]])
    // IEEE 1722 has no transport file
    let file = try await stack.send(.GET, "\(sender)/transportfile")
    XCTAssertEqual(file.status, .notFound)
  }

  /// A listener is patched with the talker's parameters and its sender ID; a transport
  /// file is refused.
  @OcaDevice
  func testAListenerIsPatchedByTheTalkersParameters() async throws {
    let (application, agent, stack) = try await makeStack()
    let sender = stack.id(application, 1001)
    let talker = try await stack.send(.GET, "senders/\(sender)/active")
    let parameters = try XCTUnwrap(talker.json?["transport_params"])
    let path = "receivers/\(stack.id(application, 1))/staged"
    let result = try await stack.send(.PATCH, path, [
      "sender_id": .string(sender.description), "master_enable": true,
      "activation": ["mode": "activate_immediate"], "transport_params": parameters,
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(
      agent.bindings.first?.talker, MilanMediaStreamEndpointIDExternal(entityID: Self.entity, streamIndex: 0)
    )

    let file: NMOSJSONValue = ["data": "{}", "type": "application/json"]
    let wrong = try await stack.send(.PATCH, path, ["transport_file": file])
    XCTAssertEqual(wrong.status, .badRequest)
    XCTAssertEqual(
      wrong.json?["error"], "IEEE 1722 receivers have no transport file; stage `transport_params` instead"
    )
  }

  @OcaDevice
  func testAPatchBindsWithConfigureConnectionAndStartsTheStream() async throws {
    let (application, agent, stack) = try await makeStack()
    let path = "receivers/\(stack.id(application, 1))"
    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["entity_id": "001122fffe334455", "stream_index": 3]],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(agent.bindings.count, 1)
    XCTAssertEqual(agent.bindings.first?.session, 1)
    XCTAssertEqual(
      agent.bindings.first?.talker, MilanMediaStreamEndpointIDExternal(entityID: Self.entity, streamIndex: 3)
    )
    XCTAssertEqual(try agent.session(1).streamingEnabled, true)

    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"], [["entity_id": "001122fffe334455", "stream_index": 3]])

    let disabled = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": false, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(disabled.status, .ok)
    XCTAssertEqual(agent.resets, [1])
    let unbound = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(unbound.json?["master_enable"], false)
  }

  @OcaDevice
  func testAnUnboundListenersStagedParametersCanBeSentBack() async throws {
    let (application, agent, stack) = try await makeStack()
    let path = "receivers/\(stack.id(application, 1))/staged"
    let staged = try await stack.send(.GET, path)
    XCTAssertEqual(staged.json?["transport_params"], [["entity_id": .null, "stream_index": .null]])
    // controllers PATCH the whole of what they read, with their one change in it
    let result = try await stack.send(.PATCH, path, [
      "master_enable": false, "transport_params": try XCTUnwrap(staged.json?["transport_params"]),
      "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertTrue(agent.bindings.isEmpty)
  }

  @OcaDevice
  func testAnEntityIDWrittenAnotherWayIsStillTheBindingTheClientMade() async throws {
    let (application, agent, stack) = try await makeStack()
    let path = "receivers/\(stack.id(application, 1))"
    let peer = NMOSID(UUID(version5: "talker", namespace: NMOSOcaResourceIDs.namespace))
    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["entity_id": "0x001122FFFE334455", "stream_index": 3]],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(
      agent.bindings.first?.talker, MilanMediaStreamEndpointIDExternal(entityID: Self.entity, streamIndex: 3)
    )
    // the session holds the entity ID as a number, which reads back as sixteen digits
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["sender_id"], .string(peer.description))
    XCTAssertEqual(active.json?["master_enable"], true)
  }

  @OcaDevice
  func testParametersThatNameNoTalkerAreRefused() async throws {
    let (application, agent, stack) = try await makeStack()
    let path = "receivers/\(stack.id(application, 1))/staged"
    for parameters: NMOSJSONValue in [
      ["entity_id": "not hexadecimal"], ["stream_index": 70000], ["stream_index": -1],
    ] {
      let result = try await stack.send(.PATCH, path, ["transport_params": [parameters]])
      XCTAssertEqual(result.status, .badRequest, "\(parameters)")
    }
    let unnamed = try await stack.send(.PATCH, path, [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(unnamed.status, .badRequest)
    XCTAssertTrue(agent.bindings.isEmpty)
  }

  @OcaDevice
  func testABindingMadeByAnATDECCControllerReachesActive() async throws {
    let (application, agent, stack) = try await makeStack()
    let path = "receivers/\(stack.id(application, 1))"
    _ = try await stack.send(.GET, "\(path)/active")
    // the session agent is a separate object from the application, and is observed too
    try agent.update(
      sessionID: 1, remote: MilanMediaStreamEndpointIDExternal(entityID: 0xAB, streamIndex: 1),
      streamingEnabled: true, localEndpointState: .running
    )
    let active = try await stack.wait(for: "\(path)/active") { $0["master_enable"] == true }
    XCTAssertEqual(active?["transport_params"], [["entity_id": "00000000000000ab", "stream_index": 1]])
  }

  /// The parameters and constraints served are those
  /// schemas/*_transport_params_ieee1722.json describe, whether the listener is bound or not.
  @OcaDevice
  func testTheParametersMeetTheIEEE1722Schemas() async throws {
    let (application, _, stack) = try await makeStack()
    let senderSchema = try TransportParamsSchema("sender_transport_params_ieee1722")
    let receiverSchema = try TransportParamsSchema("receiver_transport_params_ieee1722")
    let receiver = "receivers/\(stack.id(application, 1))"
    let sender = "senders/\(stack.id(application, 1001))"

    let talker = try await stack.send(.GET, "\(sender)/active")
    talker.json?["transport_params"]?.arrayValue?.forEach { senderSchema.check($0) }
    let senderConstraints = try await stack.send(.GET, "\(sender)/constraints")
    XCTAssertEqual(senderConstraints.json?.arrayValue?.first?.objectValue.map { Set($0.keys) }, senderSchema.properties)

    let constraints = try await stack.send(.GET, "\(receiver)/constraints")
    let leg = try XCTUnwrap(constraints.json?.arrayValue?.first?.objectValue)
    XCTAssertEqual(Set(leg.keys), receiverSchema.properties)
    XCTAssertEqual(leg["entity_id"]?["pattern"]?.stringValue, receiverSchema.pattern(of: "entity_id"))
    XCTAssertEqual(leg["stream_index"], ["minimum": 0, "maximum": 65535])
    let unbound = try await stack.send(.GET, "\(receiver)/active")
    unbound.json?["transport_params"]?.arrayValue?.forEach { receiverSchema.check($0) }
    let result = try await stack.send(.PATCH, "\(receiver)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": try XCTUnwrap(talker.json?["transport_params"]),
    ])
    XCTAssertEqual(result.status, .ok)
    let bound = try await stack.wait(for: "\(receiver)/active") { $0["master_enable"] == true }
    XCTAssertNotNil(bound)
    bound?["transport_params"]?.arrayValue?.forEach { receiverSchema.check($0) }
  }
}
