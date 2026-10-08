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
import XCTest

/// The fixtures behave as the seams say a real implementation does, so that tests built
/// on them are testing the engines and not the fixtures.
final class FixtureTests: XCTestCase {
  func testConnectionProvider() async throws {
    let provider = FixtureConnectionProvider()
    let receiver = NMOSID(UUID())
    let idle = NMOSConnectionState(masterEnable: false, transportParameters: [["destination_port": "auto"]])
    provider.add(.init(kind: .receiver, active: idle), id: receiver)

    let receivers = await provider.connections(.receiver)
    XCTAssertEqual(receivers, [receiver])
    let senders = await provider.connections(.sender)
    XCTAssertEqual(senders, [])
    do {
      _ = try await provider.active(.sender, id: receiver)
      XCTFail("a receiver is not a sender")
    } catch {
      XCTAssertEqual(error as? NMOSConnectionError, .notFound)
    }

    var staged = idle
    staged.masterEnable = true
    let active = try await provider.activate(.receiver, id: receiver, staged: staged)
    XCTAssertEqual(active, staged)
    XCTAssertEqual(provider.activations.count, 1)

    provider.changeExternally(receiver, to: idle)
    var changes = provider.connectionChanges().makeAsyncIterator()
    let signal: Void? = await changes.next()
    XCTAssertNotNil(signal)
    let current = try await provider.active(.receiver, id: receiver)
    XCTAssertEqual(current, idle)
  }

  func testDeviceModel() async throws {
    let userLabel = NcElementID(level: 1, index: 6)
    let model = FixtureDeviceModel(objects: [1: [userLabel: "Root"]])
    let propertyID = try NMOSJSONValue(encoding: userLabel)

    let session = NcSession(peer: nil)
    let read = await model.handleCommand(
      NcCommand(oid: 1, methodID: FixtureDeviceModel.get, arguments: ["id": propertyID]),
      session: session
    )
    XCTAssertEqual(read, NcMethodResult(value: "Root"))
    let missing = await model.handleCommand(
      NcCommand(oid: 2, methodID: FixtureDeviceModel.get, arguments: ["id": propertyID]),
      session: session
    )
    XCTAssertEqual(missing.status, .badOid)
    XCTAssertTrue(missing.status.isError)

    var notifications = model.notifications(for: session).makeAsyncIterator()
    let written = await model.handleCommand(
      NcCommand(oid: 1, methodID: FixtureDeviceModel.set, arguments: ["id": propertyID, "value": "Device"]),
      session: session
    )
    XCTAssertEqual(written.status, .ok)
    let notification = await notifications.next()
    XCTAssertEqual(notification?.oid, 1)
    XCTAssertEqual(notification?.eventID, .propertyChanged)
    XCTAssertEqual(notification?.eventData["value"], "Device")

    let subscribable = await model.subscribable([1, 2, 3], session: session)
    XCTAssertEqual(subscribable, [1])
    await model.sessionEnded(session)
    XCTAssertEqual(model.ended.withLock { $0 }, [session])
  }

  func testMethodResultsEncodeAsTheSpecifiedTypes() throws {
    XCTAssertEqual(try NMOSJSONValue(encoding: NcMethodResult()), ["status": 200])
    // NcMethodResultPropertyValue carries the value even when it is null
    XCTAssertEqual(try NMOSJSONValue(encoding: NcMethodResult(value: .null)), ["status": 200, "value": .null])
    XCTAssertEqual(
      try NMOSJSONValue(encoding: NcMethodResult.error(.readonly, "read only")),
      ["status": 405, "errorMessage": "read only"]
    )
  }

  func testServiceDiscovery() async throws {
    let discovery = FixtureServiceDiscovery()
    let registration = try await discovery.advertise(
      .init(type: NMOSServiceType.node, port: 8080, txt: ["api_proto": "http", "ver_slf": "0"])
    )
    try await registration.update(txt: ["api_proto": "http", "ver_slf": "1"])
    XCTAssertEqual(discovery.registrations.first?.txt["ver_slf"], "1")

    var found = discovery.browse(type: NMOSServiceType.registration).makeAsyncIterator()
    let registry = NMOSDiscoveredService(name: "reg", host: "10.0.0.9", port: 8010, txt: ["pri": "10"])
    discovery.publish([registry], type: NMOSServiceType.registration)
    let services = await found.next()
    XCTAssertEqual(services, [registry])
  }

  func testHTTPClient() async throws {
    let client = FixtureHTTPClient { request in
      NMOSHTTPClientResponse(status: request.method == .POST ? 201 : 404)
    }
    let url = try XCTUnwrap(URL(string: "http://10.0.0.9:8010/x-nmos/registration/v1.3/resource"))
    let response = try await client.send(.POST, url, body: Data("{}".utf8))
    XCTAssertEqual(response.status, 201)
    XCTAssertEqual(client.requests, [.init(method: .POST, url: url, body: Data("{}".utf8))])
  }
}
