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
import Synchronization
import XCTest

/// A Dante application as a device implements it: SetChannelEndpoint subscribes the
/// channel, and the subscription then shows in the channel endpoint.
final class TestDanteApplication: SwiftOCADevice.DanteOcaMediaTransportApplication {
  var subscriptions = [(id: OcaID16, remote: DanteChannelAddress)]()
  var cleared = [OcaID16]()
  /// When set, the subscription shows only after this long, as it does on a real device.
  var delay: Duration?
  /// When set, a subscription never shows, as when the device cannot find its transmitter.
  var neverShows = false

  func addChannel(_ id: OcaID16, name: String, direction: OcaIODirection) throws {
    insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: OcaMediaStreamEndpointID(id), idExternal: OcaBlob(Array(name.utf8)), direction: direction
    ))
    channelEndpoints[id] = try OcaChannelEndpoint(
      idExternal: OcaBlob(Array(name.utf8)), direction: direction,
      adaptationData: DanteChannelEndpointAdaptationData(streamEndpointID: OcaMediaStreamEndpointID(id)).blob
    )
  }

  /// What the device reports once a subscription, by whatever means, has taken effect.
  func show(_ remote: DanteChannelAddress, on id: OcaID16) throws {
    var channel = try channelEndpoint(id)
    var data = try channel.adaptationData.decode(DanteChannelEndpointAdaptationData.self)
    data.remoteAddress = remote
    data.subscriptionStatus = remote.device.isEmpty ? .none : .subscribedToUnicastFlow
    channel.adaptationData = try data.blob
    update(channelEndpointID: id, channel)
  }

  override func setChannelEndpoint(
    id: OcaID16,
    channelEndpoint: OcaChannelEndpoint,
    from controller: any OcaController
  ) async throws {
    let remote = try channelEndpoint.adaptationData.decode(DanteChannelEndpointAdaptationData.self).remoteAddress
    subscriptions.append((id, remote))
    guard !neverShows else { return }
    guard let delay else { return try show(remote, on: id) }
    Task { @OcaDevice in
      try? await Task.sleep(for: delay)
      try? self.show(remote, on: id)
    }
  }

  override func clearChannelEndpoint(id: OcaID16, from controller: any OcaController) async throws {
    cleared.append(id)
    try show(DanteChannelAddress(), on: id)
  }
}

final class DanteConnectionTests: XCTestCase {
  @OcaDevice
  private func makeStack() async throws -> (TestDanteApplication, ConnectionStack) {
    _ = try await TestDevice.networkManager()
    let deviceManager = await OcaDevice.shared.deviceManager
    deviceManager?.deviceName = "MonitorTwo-0A1B"
    let application = try await TestDanteApplication(
      role: TestDevice.role("Dante"), deviceDelegate: OcaDevice.shared
    )
    try application.addChannel(1, name: "01", direction: .input)
    try application.addChannel(1001, name: "Left", direction: .output)
    return try await (application, ConnectionStack([application]))
  }

  /// A transmit channel is subscribed to by the device's name, so renaming the device
  /// changes its connection: the device manager is watched, and a change signalled.
  @OcaDevice
  func testRenamingTheDeviceChangesATransmitChannelsConnection() async throws {
    let (application, stack) = try await makeStack()
    let sender = stack.id(application, 1001)
    let signals = Mutex(0)
    let changes = stack.bridge.connectionProvider.connectionChanges()
    let task = Task {
      for await _ in changes { signals.withLock { $0 += 1 } }
    }
    defer { task.cancel() }
    func count() -> Int { signals.withLock { $0 } }

    for _ in 0..<300 where count() == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(100))
    let before = count()
    XCTAssertGreaterThan(before, 0)
    let deviceManager = await OcaDevice.shared.deviceManager
    deviceManager?.deviceName = "MonitorTwo-Renamed"
    defer { deviceManager?.deviceName = "MonitorTwo-0A1B" }
    for _ in 0..<300 where count() == before {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(count(), before)
    let active = try await stack.send(.GET, "senders/\(sender)/active")
    XCTAssertEqual(active.json?["transport_params"], [["device_name": "MonitorTwo-Renamed", "channel_name": "Left"]])
  }

  @OcaDevice
  func testChannelsAreConnectionsOfTheDanteTransport() async throws {
    let (application, stack) = try await makeStack()
    let receiver = "receivers/\(stack.id(application, 1))"
    let sender = "senders/\(stack.id(application, 1001))"

    let type = try await stack.send(.GET, "\(receiver)/transporttype")
    XCTAssertEqual(type.json, "urn:x-nmos:transport:dante")
    let idle = try await stack.send(.GET, "\(receiver)/active")
    XCTAssertEqual(idle.json?["master_enable"], false)
    XCTAssertEqual(idle.json?["transport_params"], [["device_name": .null, "channel_name": .null]])
    // the patterns tell a controller the parameters are strings
    let receiverConstraints = try await stack.send(.GET, "\(receiver)/constraints")
    XCTAssertEqual(receiverConstraints.json, [[
      "device_name": ["pattern": "^[A-Za-z0-9-]{1,31}$"], "channel_name": ["pattern": "^[^@]{1,31}$"],
    ]])
    let numeric = try await stack.send(.PATCH, "\(receiver)/staged", [
      "transport_params": [["device_name": "StageBox", "channel_name": 5]],
    ])
    XCTAssertEqual(numeric.status, .badRequest)
    let cleared = try await stack.send(.PATCH, "\(receiver)/staged", [
      "transport_params": [["device_name": .null, "channel_name": .null]],
    ])
    XCTAssertEqual(cleared.status, .ok)

    // a transmit channel's parameters are what a receiver subscribes with
    let active = try await stack.send(.GET, "\(sender)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"], [["device_name": "MonitorTwo-0A1B", "channel_name": "Left"]])
    let constraints = try await stack.send(.GET, "\(sender)/constraints")
    XCTAssertEqual(constraints.json, [[
      "device_name": ["enum": ["MonitorTwo-0A1B"]], "channel_name": ["enum": ["Left"]],
    ]])
    let renamed = try await stack.send(.PATCH, "\(sender)/staged", ["transport_params": [["channel_name": "Right"]]])
    XCTAssertEqual(renamed.status, .badRequest)

    // IS-05 v1.1 knows no such transport
    let request = HTTPRequest(
      method: .GET, version: .http11, path: "/x-nmos/connection/v1.1/single/\(receiver)/staged",
      query: [], headers: [:], body: HTTPBodySequence(data: Data())
    )
    let older = try await stack.router.handleRequest(request)
    XCTAssertEqual(older.statusCode, .conflict)
  }

  @OcaDevice
  func testAPatchSubscribesWithSetChannelEndpoint() async throws {
    let (application, stack) = try await makeStack()
    let path = "receivers/\(stack.id(application, 1))"
    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["device_name": "StageBox", "channel_name": "Kick"]],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(application.subscriptions.count, 1)
    XCTAssertEqual(application.subscriptions.first?.id, 1)
    XCTAssertEqual(application.subscriptions.first?.remote, DanteChannelAddress(device: "StageBox", channel: "Kick"))

    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"], [["device_name": "StageBox", "channel_name": "Kick"]])

    let disabled = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": false, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(disabled.status, .ok)
    XCTAssertEqual(application.cleared, [1])
    let idle = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(idle.json?["master_enable"], false)

    // enabling with nothing to subscribe to is the client's mistake
    let nothing = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["device_name": .null, "channel_name": .null]],
    ])
    XCTAssertEqual(nothing.status, .badRequest)
  }

  /// Dante has no transport file, so a receiver is patched with the sender's parameters.
  @OcaDevice
  func testASenderHasNoTransportFileAndAReceiverIsPatchedByItsParameters() async throws {
    let (application, stack) = try await makeStack()
    let sender = stack.id(application, 1001)
    let file = try await stack.send(.GET, "senders/\(sender)/transportfile")
    XCTAssertEqual(file.status, .notFound)
    let talker = try await stack.send(.GET, "senders/\(sender)/active")
    let parameters = try XCTUnwrap(talker.json?["transport_params"])
    XCTAssertEqual(parameters, [["device_name": "MonitorTwo-0A1B", "channel_name": "Left"]])

    let path = "receivers/\(stack.id(application, 1))/staged"
    let result = try await stack.send(.PATCH, path, [
      "sender_id": .string(sender.description), "master_enable": true,
      "activation": ["mode": "activate_immediate"], "transport_params": parameters,
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(
      application.subscriptions.first?.remote, DanteChannelAddress(device: "MonitorTwo-0A1B", channel: "Left")
    )

    // a transport file is refused, whatever its type; a null one is not a file
    for type in ["application/sdp", "application/json"] {
      let file: NMOSJSONValue = ["data": "v=0\r\n", "type": .string(type)]
      let wrong = try await stack.send(.PATCH, path, ["transport_file": file])
      XCTAssertEqual(wrong.status, .badRequest)
    }
    let none = try await stack.send(.PATCH, path, ["transport_file": ["data": .null, "type": .null]])
    XCTAssertEqual(none.status, .ok)
  }

  @OcaDevice
  func testAnActivationWaitsForTheDeviceToShowTheSubscription() async throws {
    let (application, stack) = try await makeStack()
    application.delay = .milliseconds(150)
    let peer = NMOSID(UUID(version5: "peer", namespace: NMOSOcaResourceIDs.namespace))
    let path = "receivers/\(stack.id(application, 1))"
    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["device_name": "StageBox", "channel_name": "Snare"]],
    ])
    XCTAssertEqual(result.status, .ok)
    // the response is the result of the activation, not what the channel was doing before
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["sender_id"], .string(peer.description))
  }

  @OcaDevice
  func testAnActivationTheDeviceNeverShowsStopsWaiting() async throws {
    let (application, stack) = try await makeStack()
    application.neverShows = true
    let path = "receivers/\(stack.id(application, 1))"
    let started = ContinuousClock.now
    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["device_name": "StageBox", "channel_name": "Tom"]],
    ])
    let waited = started.duration(to: .now)
    XCTAssertEqual(result.status, .ok)
    XCTAssertGreaterThanOrEqual(waited, .seconds(2))
    XCTAssertLessThan(waited, .seconds(3))
  }

  @OcaDevice
  func testAChannelIsFoundByItsNumberUnlessAnotherNamesItsStreamEndpoint() async throws {
    let (application, stack) = try await makeStack()
    func channel(_ remote: String, naming id: OcaMediaStreamEndpointID) throws -> OcaChannelEndpoint {
      try OcaChannelEndpoint(
        idExternal: OcaBlob("01".utf8), direction: .input,
        adaptationData: DanteChannelEndpointAdaptationData(
          remoteAddress: DanteChannelAddress(device: remote, channel: "01"), streamEndpointID: id
        ).blob
      )
    }
    func device(_ id: OcaMediaStreamEndpointID) async throws -> NMOSJSONValue? {
      try await stack.parameters("receivers/\(stack.id(application, id))/active")?["device_name"]
    }
    for id in [2, 3] as [OcaID16] {
      application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: OcaMediaStreamEndpointID(id), direction: .input))
    }
    // a device may leave its channel endpoints naming no stream endpoint
    application.channelEndpoints[2] = try channel("Unnamed", naming: 0)
    // channel 3 is stream endpoint 9's, and channel 9 is stream endpoint 3's
    application.channelEndpoints[3] = try channel("Other", naming: 9)
    application.channelEndpoints[9] = try channel("Named", naming: 3)

    let unnamed = try await device(2)
    XCTAssertEqual(unnamed, "Unnamed")
    let named = try await device(3)
    XCTAssertEqual(named, "Named")
  }

  @OcaDevice
  func testASubscriptionMadeInDanteControllerReachesActive() async throws {
    let (application, stack) = try await makeStack()
    let path = "receivers/\(stack.id(application, 1))"
    _ = try await stack.send(.GET, "\(path)/active")
    try application.show(DanteChannelAddress(device: "Console", channel: "Mix L"), on: 1)
    let active = try await stack.wait(for: "\(path)/active") { $0["master_enable"] == true }
    XCTAssertEqual(active?["transport_params"], [["device_name": "Console", "channel_name": "Mix L"]])
    // what is staged follows what the channel is now doing
    let staged = try await stack.wait(for: "\(path)/staged") {
      $0["transport_params"]?.arrayValue?.first?["device_name"] == "Console"
    }
    XCTAssertEqual(staged?["master_enable"], true)
  }
}
