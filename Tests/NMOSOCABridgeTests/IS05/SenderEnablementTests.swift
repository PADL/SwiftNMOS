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

/// An IEEE 1722 entity's application whose talkers are started and stopped with
/// ApplyEndpointCommand, as one that sends START_STREAMING and STOP_STREAMING can; a
/// stopped talker is Connected, a started one Ready.
final class TestStoppableApplication: SwiftOCADevice.OcaMediaTransportApplication {
  var calls = [(id: OcaMediaStreamEndpointID, command: OcaMediaStreamEndpointCommand)]()
  /// When set, the device refuses the command.
  var refusal: OcaStatus?

  override func applyEndpointCommand(
    endpointID id: OcaMediaStreamEndpointID,
    command: OcaMediaStreamEndpointCommand,
    from controller: any OcaController
  ) async throws {
    calls.append((id, command))
    if let refusal { throw Ocp1Error.status(refusal) }
    guard command == .start || command == .stop else { throw Ocp1Error.status(.notImplemented) }
    update(endpointID: id, status: .init(state: command == .stop ? .connected : .ready))
  }
}

final class SenderEnablementTests: XCTestCase {
  private static let entity: OcaUint64 = 0x0011_22FF_FE33_4455

  @OcaDevice
  private func makeApplication(_ application: SwiftOCADevice.OcaMediaTransportApplication) throws {
    application.adaptationIdentifier = MilanAdaptation.identifier
    try application.insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: 1001,
      idExternal: MilanMediaStreamEndpointIDExternal(entityID: Self.entity, streamIndex: 0).blob,
      direction: .output
    ), status: .init(state: .ready))
  }

  @OcaDevice
  private func makeStack() async throws -> (TestStoppableApplication, ConnectionStack) {
    _ = try await TestDevice.networkManager()
    let application = try await TestStoppableApplication(
      role: TestDevice.role("Talker"), deviceDelegate: OcaDevice.shared
    )
    try makeApplication(application)
    return try await (application, ConnectionStack([application]))
  }

  @OcaDevice
  private func patch(_ stack: ConnectionStack, _ path: String, enable: Bool) async throws -> HTTPStatusCode {
    try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": .bool(enable), "activation": ["mode": "activate_immediate"],
    ]).status
  }

  @OcaDevice
  func testDisablingASenderStopsItsTransmissionAndActiveSaysSo() async throws {
    let (application, stack) = try await makeStack()
    let sender = await stack.id(application, 1001)
    let path = "senders/\(sender)"
    let before = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(before.json?["master_enable"], true)

    let status = try await patch(stack, path, enable: false)
    XCTAssertEqual(status, .ok)
    XCTAssertEqual(application.calls.map(\.command), [.stop])
    XCTAssertEqual(try application.endpointStatus(1001).state, .connected)
    let after = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(after.json?["master_enable"], false)
    // the transport parameters are the talker's own, whether or not it transmits
    XCTAssertEqual(after.json?["transport_params"], [["entity_id": "001122fffe334455", "stream_index": 0]])
    let described = await stack.store.senders.first { $0.id == sender }
    XCTAssertEqual(described?.subscription.active, false)

    let status1 = try await patch(stack, path, enable: true)
    XCTAssertEqual(status1, .ok)
    XCTAssertEqual(application.calls.map(\.command), [.stop, .start])
    let enabled = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(enabled.json?["master_enable"], true)
  }

  @OcaDevice
  func testAnUnchangedEnablementIsNotSentToTheDevice() async throws {
    let (application, stack) = try await makeStack()
    let path = "senders/\(await stack.id(application, 1001))"
    let status2 = try await patch(stack, path, enable: true)
    XCTAssertEqual(status2, .ok)
    XCTAssertTrue(application.calls.isEmpty)
  }

  @OcaDevice
  func testAStopMadeElsewhereReachesActive() async throws {
    let (application, stack) = try await makeStack()
    let path = "senders/\(await stack.id(application, 1001))"
    application.update(endpointID: 1001, status: .init(state: .connected))
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
  }

  @OcaDevice
  func testARefusalByTheDeviceLeavesTheSenderAsItWas() async throws {
    let (application, stack) = try await makeStack()
    let path = "senders/\(await stack.id(application, 1001))"
    application.refusal = .locked
    let status3 = try await patch(stack, path, enable: false)
    XCTAssertEqual(status3, .locked)
    application.refusal = .deviceError
    let status4 = try await patch(stack, path, enable: false)
    XCTAssertEqual(status4, .internalServerError)
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
  }

  /// A sender whose application cannot stop it refuses with NotImplemented, and a request
  /// to disable it meets the schema and the constraints but cannot be carried out: a 500.
  @OcaDevice
  func testASenderThatCannotBeDisabledRefusesWithAServerError() async throws {
    _ = try await TestDevice.networkManager()
    let application = try await TestDevice.makeApplication("Talker")
    try makeApplication(application)
    let stack = try await ConnectionStack([application])
    let path = "senders/\(await stack.id(application, 1001))"

    let refused = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": false, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(refused.status, .internalServerError)
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    // what it is already doing is accepted
    let status5 = try await patch(stack, path, enable: true)
    XCTAssertEqual(status5, .ok)
  }
}
