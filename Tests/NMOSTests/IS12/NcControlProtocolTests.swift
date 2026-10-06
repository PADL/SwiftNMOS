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
import Logging
@testable import NMOS
import Synchronization
import XCTest

/// A fixture model that also records what the engine tells it of each session: the
/// session every command was for, its subscriptions, and its end.
private final class RecordingDeviceModel: NcDeviceModel {
  let fixture: FixtureDeviceModel
  let handled = Mutex([NcSession]())
  let subscriptions = Mutex([NcSession: Set<NcOid>]())
  let ended = Mutex([NcSession]())

  init(objects: [NcOid: [NcElementID: NMOSJSONValue]]) {
    fixture = FixtureDeviceModel(objects: objects)
  }

  func handleCommand(_ command: NcCommand, session: NcSession) async -> NcMethodResult {
    handled.withLock { $0.append(session) }
    return await fixture.handleCommand(command, session: session)
  }

  func subscribable(_ oids: [NcOid], session: NcSession) async -> [NcOid] {
    await fixture.subscribable(oids, session: session)
  }

  func notifications(for session: NcSession) -> AsyncStream<NcNotification> {
    fixture.notifications(for: session)
  }

  func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {
    subscriptions.withLock { $0[session] = oids }
  }

  func sessionEnded(_ session: NcSession) async {
    await fixture.sessionEnded(session)
    subscriptions.withLock { $0[session] = nil }
    ended.withLock { $0.append(session) }
  }
}

/// A controller's end of a control session, as the WebSocket handler sees it.
private final class Client {
  let session: NcSession
  private let toDevice: AsyncStream<WSMessage>.Continuation
  private var fromDevice: AsyncStream<WSMessage>.AsyncIterator

  init(_ model: any NcDeviceModel, peer: NcSession.Peer? = .ip("192.0.2.7", port: 49152)) async throws {
    session = NcSession(peer: peer)
    let connection = NcControlConnection(model: model, session: session, logger: Logger(label: "test"))
    let (input, continuation) = AsyncStream<WSMessage>.makeStream()
    toDevice = continuation
    fromDevice = try await connection.makeMessages(for: input).makeAsyncIterator()
  }

  func send(_ json: String) { toDevice.yield(.text(json)) }
  func close() { toDevice.finish() }

  /// The next message from the device; fails the test rather than hang if none comes.
  func receive() async throws -> NMOSJSONValue {
    guard case let .text(text) = await fromDevice.next() else {
      throw XCTSkip("the session ended without a message")
    }
    return try NMOSJSONValue(data: Data(text.utf8))
  }

  func exchange(_ json: String) async throws -> NMOSJSONValue {
    send(json)
    return try await receive()
  }
}

/// The IS-12 protocol engine against a fixture device model. The JSON is that of the
/// examples in the IS-12 documentation.
final class NcControlProtocolTests: XCTestCase {
  private static let userLabel = NcElementID(level: 1, index: 6)
  private static let classID = NcElementID(level: 1, index: 1)

  private var model: RecordingDeviceModel!

  override func setUp() {
    model = RecordingDeviceModel(objects: [
      1: [Self.classID: [1, 1], Self.userLabel: "Root"],
      100: [Self.userLabel: .null],
      98119: [Self.classID: [1, 7, 1], Self.userLabel: "Input 0"],
    ])
  }

  private func json(_ text: String) throws -> NMOSJSONValue { try NMOSJSONValue(data: Data(text.utf8)) }

  func testSetAnswersWithoutAValue() async throws {
    let client = try await Client(model)
    let response = try await client.exchange("""
    {"messageType": 0, "commands": [{"handle": 2, "oid": 98119, "methodId": {"level": 1, "index": 2},
      "arguments": {"id": {"level": 1, "index": 6}, "value": "My new label"}}]}
    """)
    XCTAssertEqual(response, try json("""
    {"messageType": 1, "responses": [{"handle": 2, "result": {"status": 200}}]}
    """))
    XCTAssertEqual(model.fixture.value(oid: 98119, property: Self.userLabel), "My new label")
  }

  func testGetAnswersWithTheValue() async throws {
    let client = try await Client(model)
    let response = try await client.exchange("""
    {"messageType": 0, "commands": [{"handle": 2, "oid": 98119, "methodId": {"level": 1, "index": 1},
      "arguments": {"id": {"level": 1, "index": 1}}}]}
    """)
    XCTAssertEqual(response, try json("""
    {"messageType": 1, "responses": [{"handle": 2, "result": {"status": 200, "value": [1, 7, 1]}}]}
    """))
  }

  func testTheFieldsOfADerivedResultAreWrittenBesideItsStatus() {
    let result = NcMethodResult(fields: ["NamePath": ["Root", "Gain"], "ONoPath": [100, 4097]])
    XCTAssertEqual(
      NcProtocolCodec.json(result), ["status": 200, "NamePath": ["Root", "Gain"], "ONoPath": [100, 4097]]
    )
  }

  func testANullValueIsWrittenAsNull() async throws {
    let client = try await Client(model)
    let response = try await client.exchange("""
    {"messageType": 0, "commands": [{"handle": 7, "oid": 100, "methodId": {"level": 1, "index": 1},
      "arguments": {"id": {"level": 1, "index": 6}}}]}
    """)
    XCTAssertEqual(response["responses"]?.arrayValue?.first?["result"], ["status": 200, "value": .null])
  }

  func testSeveralCommandsAreAnsweredInOneMessageInOrder() async throws {
    let client = try await Client(model)
    let response = try await client.exchange("""
    {"messageType": 0, "commands": [
      {"handle": 10, "oid": 98119, "methodId": {"level": 1, "index": 2},
       "arguments": {"id": {"level": 1, "index": 6}, "value": "Renamed"}},
      {"handle": 11, "oid": 98119, "methodId": {"level": 1, "index": 1},
       "arguments": {"id": {"level": 1, "index": 6}}},
      {"handle": 12, "oid": 4242, "methodId": {"level": 1, "index": 1},
       "arguments": {"id": {"level": 1, "index": 6}}}]}
    """)
    let responses = try XCTUnwrap(response["responses"]?.arrayValue)
    XCTAssertEqual(responses.map { $0["handle"] }, [10, 11, 12])
    XCTAssertEqual(responses[1]["result"], ["status": 200, "value": "Renamed"])
    XCTAssertEqual(responses[2]["result"]?["status"], 404)
    XCTAssertNotNil(responses[2]["result"]?["errorMessage"]?.stringValue)
  }

  func testErrorsOfAMethodAreCommandResponses() async throws {
    let client = try await Client(model)
    for (command, status) in [
      // an unknown property, an unknown method, and arguments that are not the method's
      (#"{"handle": 1, "oid": 1, "methodId": {"level": 1, "index": 1}, "arguments": {"id": {"level": 1, "index": 999}}}"#, 502),
      (#"{"handle": 1, "oid": 1, "methodId": {"level": 1, "index": 999}, "arguments": {"id": {"level": 1, "index": 6}}}"#, 501),
      (#"{"handle": 1, "oid": 1, "methodId": {"level": 1, "index": 1}, "arguments": {"id": "userLabel"}}"#, 417),
      // a command that can be answered but not carried out
      (#"{"handle": 1, "methodId": {"level": 1, "index": 1}}"#, 400),
      (#"{"handle": 1, "oid": 1, "methodId": {"level": 0}}"#, 400),
      (#"{"handle": 1, "oid": 1, "methodId": {"level": 1, "index": 1}, "arguments": [1]}"#, 400),
    ] {
      let response = try await client.exchange(#"{"messageType": 0, "commands": [\#(command)]}"#)
      XCTAssertEqual(response["messageType"], 1, command)
      let result = try XCTUnwrap(response["responses"]?.arrayValue?.first)
      XCTAssertEqual(result["handle"], 1, command)
      XCTAssertEqual(result["result"]?["status"], .integer(Int64(status)), command)
      XCTAssertNotNil(result["result"]?["errorMessage"]?.stringValue, command)
      XCTAssertNil(result["result"]?["value"], command)
    }
  }

  func testWhatCannotBeAnsweredUnderAHandleIsAnErrorMessage() async throws {
    let client = try await Client(model)
    for message in [
      "NOT JSON",
      "[1, 2, 3]",
      #"{"not_a": "valid_command"}"#,
      #"{"messageType": 7, "commands": []}"#,
      #"{"messageType": "0"}"#,
      // messages only a device sends
      #"{"messageType": 1, "responses": []}"#,
      #"{"messageType": 0}"#,
      #"{"messageType": 3, "subscriptions": ["1"]}"#,
      #"{"messageType": 0, "commands": [{"oid": 1, "methodId": {"level": 1, "index": 1}}]}"#,
      #"{"messageType": 0, "commands": [{"handle": "NOT A HANDLE", "oid": 1, "methodId": {"level": 1, "index": 1}}]}"#,
      #"{"messageType": 0, "commands": [{"handle": 999999999, "oid": 1, "methodId": {"level": 1, "index": 1}}]}"#,
      #"{"messageType": 0, "commands": [{"handle": 0, "oid": 1, "methodId": {"level": 1, "index": 1}}]}"#,
    ] {
      let response = try await client.exchange(message)
      XCTAssertEqual(response["messageType"], 5, message)
      XCTAssertEqual(response["status"], 400, message)
      XCTAssertNotNil(response["errorMessage"]?.stringValue, message)
      XCTAssertEqual(response.objectValue?.count, 3, message)
    }
    // the session survives them
    let response = try await client.exchange(#"{"messageType": 3, "subscriptions": []}"#)
    XCTAssertEqual(response, ["messageType": 4, "subscriptions": []])
  }

  func testSubscriptionKeepsTheObjectsThatExist() async throws {
    let client = try await Client(model)
    let response = try await client.exchange("""
    {"messageType": 3, "subscriptions": [1, 100, 111, 98119]}
    """)
    XCTAssertEqual(response, try json("""
    {"messageType": 4, "subscriptions": [1, 100, 98119]}
    """))
  }

  func testASubscribedSessionIsNotifiedAndOthersAreNot() async throws {
    let subscriber = try await Client(model)
    let bystander = try await Client(model)
    _ = try await subscriber.exchange(#"{"messageType": 3, "subscriptions": [98119]}"#)
    _ = try await bystander.exchange(#"{"messageType": 3, "subscriptions": [1]}"#)

    let response = try await bystander.exchange("""
    {"messageType": 0, "commands": [{"handle": 3, "oid": 98119, "methodId": {"level": 1, "index": 2},
      "arguments": {"id": {"level": 1, "index": 6}, "value": "Input 1"}}]}
    """)
    XCTAssertEqual(response["messageType"], 1)

    let notification = try await subscriber.receive()
    XCTAssertEqual(notification, try json("""
    {"messageType": 2, "notifications": [{"oid": 98119, "eventId": {"level": 1, "index": 1},
      "eventData": {"propertyId": {"level": 1, "index": 6}, "changeType": 0, "value": "Input 1",
                    "sequenceItemIndex": null}}]}
    """))

    // the bystander's next message is the answer to its next command, not a notification
    let next = try await bystander.exchange(#"{"messageType": 3, "subscriptions": []}"#)
    XCTAssertEqual(next["messageType"], 4)
  }

  func testASubscriptionMessageReplacesTheOneBefore() async throws {
    let client = try await Client(model)
    _ = try await client.exchange(#"{"messageType": 3, "subscriptions": [1, 98119]}"#)
    _ = try await client.exchange(#"{"messageType": 3, "subscriptions": [1]}"#)

    // a change to the object it dropped is not reported; one to the object it kept is
    for oid in [98119, 1] {
      client.send("""
      {"messageType": 0, "commands": [{"handle": 1, "oid": \(oid), "methodId": {"level": 1, "index": 2},
        "arguments": {"id": {"level": 1, "index": 6}, "value": "Changed"}}]}
      """)
    }
    // a notification may come before or after the response to the command that caused it
    var responses = 0
    var notified = [NMOSJSONValue]()
    while responses < 2 || notified.isEmpty {
      let message = try await client.receive()
      if message["messageType"] == 2 {
        notified += message["notifications"]?.arrayValue ?? []
      } else {
        responses += 1
      }
    }
    XCTAssertEqual(notified.map { $0["oid"] }, [1])
  }

  func testEachConnectionIsASessionOfItsOwnToTheModel() async throws {
    let first = try await Client(model, peer: .ip("192.0.2.7", port: 49152))
    let second = try await Client(model, peer: .ip("2001:db8::7", port: 49153))
    XCTAssertNotEqual(first.session, second.session)
    XCTAssertEqual(first.session.description, "192.0.2.7:49152")
    XCTAssertEqual(second.session.description, "[2001:db8::7]:49153")
    XCTAssertEqual(NcSession(peer: .local("/run/ocad.socket")).description, "/run/ocad.socket")

    // the model is told whose command each one is
    for client in [first, second, first] {
      _ = try await client.exchange("""
      {"messageType": 0, "commands": [{"handle": 1, "oid": 1, "methodId": {"level": 1, "index": 1},
        "arguments": {"id": {"level": 1, "index": 6}}}]}
      """)
    }
    XCTAssertEqual(model.handled.withLock { $0 }, [first.session, second.session, first.session])

    // and each session's subscriptions are its own
    _ = try await first.exchange(#"{"messageType": 3, "subscriptions": [1, 100]}"#)
    _ = try await second.exchange(#"{"messageType": 3, "subscriptions": [100, 98119]}"#)
    XCTAssertEqual(model.subscriptions.withLock { $0 }, [
      first.session: [1, 100], second.session: [100, 98119],
    ])
  }

  func testAClosedConnectionEndsItsSessionAndNoOther() async throws {
    let first = try await Client(model)
    let second = try await Client(model)
    _ = try await first.exchange(#"{"messageType": 3, "subscriptions": [1]}"#)
    _ = try await second.exchange(#"{"messageType": 3, "subscriptions": [1]}"#)

    first.close()
    try await expectEnded([first.session])
    XCTAssertEqual(model.subscriptions.withLock { $0 }, [second.session: [1]])
    // the other carries on
    let response = try await second.exchange(#"{"messageType": 3, "subscriptions": []}"#)
    XCTAssertEqual(response["messageType"], 4)
    second.close()
    try await expectEnded([first.session, second.session])
  }

  private func expectEnded(_ expected: [NcSession]) async throws {
    for _ in 0..<200 {
      if model.ended.withLock({ $0 }) == expected { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("the model was not told that \(expected) ended")
  }
}

