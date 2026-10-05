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
@testable import NMOSOCABridge
import SwiftOCA
import SwiftOCADevice
import XCTest

/// A device with an AES67, a Dante and a Milan application, and one the bridge has no
/// adaptation for, on the device the bridge tests share.
@OcaDevice
private struct TestTransports {
  let manager: SwiftOCADevice.OcaNetworkManager
  let aes67: SwiftOCADevice.OcaMediaTransportApplication
  let dante: SwiftOCADevice.OcaMediaTransportApplication
  let milan: SwiftOCADevice.OcaMediaTransportApplication
  let unknown: SwiftOCADevice.OcaMediaTransportApplication
  let mediaClock: SwiftOCADevice.OcaMediaClock3
  let timeSource: SwiftOCADevice.OcaTimeSource
  let freeRunningClock: SwiftOCADevice.OcaMediaClock3
  let interface: SwiftOCADevice.OcaNetworkInterface

  static func role(_ name: String) -> String { "\(name)-\(UUID().uuidString)" }

  static let stream = "v=0\r\no=- 1 1 IN IP4 10.0.0.5\r\ns=Program\r\nt=0 0\r\nm=audio 5004 RTP/AVP 97\r\n"
    + "c=IN IP4 239.69.1.2/32\r\na=rtpmap:97 L24/48000/2\r\na=sendonly\r\n"

  init() async throws {
    manager = try await TestDevice.networkManager()
    let device = OcaDevice.shared

    timeSource = try await SwiftOCADevice.OcaTimeSource(role: Self.role("PTP"), deviceDelegate: device)
    timeSource.timeDeliveryMechanism = .ieee1588v2
    timeSource.referenceID = "00:1D:C1:FF:FE:12:34:56:0"
    timeSource.syncStatus = .synchronized
    mediaClock = try await SwiftOCADevice.OcaMediaClock3(role: Self.role("Clock"), deviceDelegate: device)
    mediaClock.timeSourceONo = timeSource.objectNumber
    mediaClock.currentRate = OcaMediaClockRate(nominalRate: 96000)
    freeRunningClock = try await SwiftOCADevice.OcaMediaClock3(role: Self.role("Free"), deviceDelegate: device)

    interface = try await SwiftOCADevice.OcaNetworkInterface(role: Self.role("Interface"), deviceDelegate: device)
    interface.systemIOInterfaceName = "lan0"
    let assignment = OcaNetworkInterfaceAssignment(
      id: 1, networkInterfaceONo: interface.objectNumber, networkBindingParameters: OcaBlob(),
      securityKeyIdentities: [], advertisingMechanisms: []
    )

    aes67 = try await SwiftOCADevice.Aes67OcaMediaTransportApplication(role: Self.role("AES67"), deviceDelegate: device)
    aes67.label = "AES67"
    aes67.networkInterfaceAssignments = [assignment]
    aes67.ports = [
      OcaPort(owner: aes67.objectNumber, id: OcaPortID(mode: .input, index: 1), name: "Mix L"),
      OcaPort(owner: aes67.objectNumber, id: OcaPortID(mode: .input, index: 2), name: "Mix R"),
    ]
    aes67.mediaStreamModeCapabilities = [OcaMediaStreamModeCapability(
      id: 1, name: "Linear", direction: [.input, .output], frameFormatList: [.rtp],
      encodingTypeList: ["audio/L24", "audio/L16"], samplingRateList: [48000], channelCountList: [],
      channelCountRange: OcaInterval(1...8), packetTimeList: [1e-3], packetTimeRange: OcaInterval(1e-3...1e-3)
    )]
    aes67.insert(
      endpoint: OcaMediaStreamEndpoint(
        idInternal: 1001, direction: .output, userLabel: "Program",
        networkAssignmentIDs: [1], streamModeCapabilityIDs: [1], clockONo: mediaClock.objectNumber,
        channelMap: [1: [OcaPortID(mode: .input, index: 1)], 2: [OcaPortID(mode: .input, index: 2)]],
        currentStreamMode: OcaMediaStreamMode(
          frameFormat: .rtp, encodingType: "audio/L24", samplingRate: 48000, channelCount: 2, packetTime: 1e-3
        ),
        streamCastMode: .multicast,
        // an endpoint is active while it has a stream configured, which this description is
        adaptationData: try Aes67EndpointAdaptationData(activeSDP: Self.stream).blob
      ),
      status: .init(state: .running)
    )
    aes67.insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: 1, direction: .input, networkAssignmentIDs: [1], streamModeCapabilityIDs: [1],
      clockONo: mediaClock.objectNumber
    ), status: .init(state: .ready))

    let dante = try await SwiftOCADevice.DanteOcaMediaTransportApplication(role: Self.role("Dante"), deviceDelegate: device)
    self.dante = dante
    dante.insert(
      endpoint: OcaMediaStreamEndpoint(
        idInternal: 1001, idExternal: OcaBlob("Left".utf8), direction: .output,
        clockONo: freeRunningClock.objectNumber
      ),
      status: .init(state: .ready)
    )
    dante.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input), status: .init(state: .connected))
    // a receive channel is active while it is subscribed, which its channel endpoint says
    dante.channelEndpoints[1] = try OcaChannelEndpoint(
      idExternal: OcaBlob("01".utf8), direction: .input,
      adaptationData: DanteChannelEndpointAdaptationData(
        remoteAddress: DanteChannelAddress(device: "StageBox", channel: "Kick"), streamEndpointID: 1
      ).blob
    )

    milan = try await TestDevice.makeApplication("Milan")
    milan.adaptationIdentifier = MilanAdaptation.identifier
    milan.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input), status: .init(state: .notReady))

    unknown = try await TestDevice.makeApplication("Unknown")
    unknown.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input))

    manager.networkInterfaces = [interface]
    manager.networkApplications = [aes67, dante, milan, unknown]
  }
}

private func host() -> NMOSOcaHost {
  NMOSOcaHost(
    seed: "00-22-97-01-02-03",
    hostname: "monitortwo",
    endpoints: [.init(host: "10.0.0.5", port: 8080)],
    interfaces: [.init(name: "lan0", chassisID: nil, portID: "00-22-97-01-02-03")]
  )
}

private func waitFor(
  _ what: String,
  _ condition: @Sendable () async -> Bool,
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  for _ in 0..<300 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  XCTFail("timed out waiting until \(what)", file: file, line: line)
}

final class NMOSOcaResourceDescriptionTests: XCTestCase {
  @OcaDevice
  func testDescribesASenderWithItsSourceAndFlow() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()
    let ids = NMOSOcaResourceIDs(seed: host().seed)
    let application = transports.aes67.objectNumber

    let senders = await store.senders
    let sender = try XCTUnwrap(senders.first { $0.id == ids.id(.sender, application: application, endpoint: 1001) })
    XCTAssertEqual(sender.label, "Program")
    XCTAssertEqual(sender.description, "AES67 output 1001")
    XCTAssertEqual(sender.transport, "urn:x-nmos:transport:rtp.mcast")
    XCTAssertEqual(sender.deviceID, ids.device)
    XCTAssertEqual(sender.interfaceBindings, ["lan0"])
    XCTAssertEqual(sender.subscription, .init(receiverID: nil, active: true))
    XCTAssertEqual(
      sender.manifestHref,
      "http://10.0.0.5:8080/x-nmos/connection/v1.1/single/senders/\(sender.id)/transportfile"
    )

    let flows = await store.flows
    let flow = try XCTUnwrap(flows.first { $0.id == sender.flowID })
    XCTAssertEqual(flow.id, ids.id(.flow, application: application, endpoint: 1001))
    XCTAssertEqual(flow.sampleRate, NMOSRational(numerator: 48000))
    XCTAssertEqual(flow.mediaType, "audio/L24")
    XCTAssertEqual(flow.bitDepth, 24)
    XCTAssertEqual(flow.deviceID, ids.device)

    let sources = await store.sources
    let source = try XCTUnwrap(sources.first { $0.id == flow.sourceID })
    XCTAssertEqual(source.id, ids.id(.source, application: application, endpoint: 1001))
    XCTAssertEqual(source.channels.map(\.label), ["Mix L", "Mix R"])
    XCTAssertEqual(source.clockName, "clk0")
    XCTAssertEqual(source.deviceID, ids.device)
  }

  @OcaDevice
  func testDescribesAReceiverWithWhatItAccepts() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()
    let ids = NMOSOcaResourceIDs(seed: host().seed)

    let receivers = await store.receivers
    let receiver = try XCTUnwrap(receivers.first {
      $0.id == ids.id(.receiver, application: transports.aes67.objectNumber, endpoint: 1)
    })
    XCTAssertEqual(receiver.label, "Receiver 1")
    // a receiver takes unicast or multicast, so it gives no subclassification
    XCTAssertEqual(receiver.transport, "urn:x-nmos:transport:rtp")
    XCTAssertEqual(receiver.caps.mediaTypes, ["audio/L24", "audio/L16"])
    XCTAssertEqual(receiver.interfaceBindings, ["lan0"])
    XCTAssertEqual(receiver.subscription, .init(senderID: nil, active: false))
    XCTAssertEqual(receiver.format, "urn:x-nmos:format:audio")
  }

  @OcaDevice
  func testGivesEachTransportItsOwnURNAndLeavesOutWhatItCannotDescribe() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()
    let ids = NMOSOcaResourceIDs(seed: host().seed)
    let senders = await store.senders
    let receivers = await store.receivers

    let danteSender = try XCTUnwrap(senders.first {
      $0.id == ids.id(.sender, application: transports.dante.objectNumber, endpoint: 1001)
    })
    XCTAssertEqual(danteSender.transport, "urn:x-nmos:transport:dante")
    XCTAssertEqual(danteSender.label, "Left")
    // a Dante transmit channel sends to whoever subscribes
    XCTAssertTrue(danteSender.subscription.active)
    // Dante has no transport file
    XCTAssertNil(danteSender.manifestHref)
    // no interface is assigned, so none is bound
    XCTAssertEqual(danteSender.interfaceBindings, [])

    let danteReceiver = try XCTUnwrap(receivers.first {
      $0.id == ids.id(.receiver, application: transports.dante.objectNumber, endpoint: 1)
    })
    XCTAssertEqual(danteReceiver.transport, "urn:x-nmos:transport:dante")
    XCTAssertTrue(danteReceiver.subscription.active)
    XCTAssertEqual(danteReceiver.caps.mediaTypes, ["audio/L24"])

    let milanReceiver = try XCTUnwrap(receivers.first {
      $0.id == ids.id(.receiver, application: transports.milan.objectNumber, endpoint: 1)
    })
    XCTAssertEqual(milanReceiver.transport, "urn:x-nmos:transport:milan")
    XCTAssertFalse(milanReceiver.subscription.active)

    XCTAssertEqual(senders.count, 2)
    XCTAssertEqual(receivers.count, 3)
    let unknown = ids.id(.receiver, application: transports.unknown.objectNumber, endpoint: 1)
    XCTAssertFalse(receivers.contains { $0.id == unknown })

    // a source has a channel even where the stream says nothing of its channels
    let sources = await store.sources
    XCTAssertEqual(sources.count, 2)
    XCTAssertFalse(sources.contains { $0.channels.isEmpty })

    // the flow of a stream that gives no rate takes its media clock's, else 48 kHz
    let flows = await store.flows
    let danteFlow = try XCTUnwrap(flows.first { $0.id == danteSender.flowID })
    XCTAssertEqual(danteFlow.sampleRate, NMOSRational(numerator: 48000))
  }

  @OcaDevice
  func testAMilanSenderHasNoTransportFile() async throws {
    let transports = try await TestTransports()
    try transports.milan.insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: 1001,
      idExternal: MilanMediaStreamEndpointIDExternal(entityID: 0x0011_22FF_FE33_4455, streamIndex: 0).blob,
      direction: .output
    ))
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()
    let ids = NMOSOcaResourceIDs(seed: host().seed)
    let senders = await store.senders
    let sender = try XCTUnwrap(senders.first {
      $0.id == ids.id(.sender, application: transports.milan.objectNumber, endpoint: 1001)
    })
    XCTAssertEqual(sender.transport, "urn:x-nmos:transport:milan")
    XCTAssertNil(sender.manifestHref)
  }

  @OcaDevice
  func testDescribesTheDeviceWithItsControls() async throws {
    _ = try await TestTransports()
    let store = NMOSResourceStore()
    let controls = [
      NMOSControl(type: "urn:x-nmos:control:sr-ctrl/v1.1", path: "connection/v1.1/"),
      NMOSControl(type: "urn:x-nmos:control:ncp/v1.0", path: "ncp/v1.0", isWebSocket: true),
    ]
    let bridge = NMOSOcaBridge(store: store, controls: controls) { host() }
    await bridge.describe()
    let ids = NMOSOcaResourceIDs(seed: host().seed)

    let devices = await store.devices
    XCTAssertEqual(devices.count, 1)
    let device = try XCTUnwrap(devices.first)
    XCTAssertEqual(device.id, ids.device)
    XCTAssertEqual(device.nodeID, ids.node)
    XCTAssertEqual(device.type, "urn:x-nmos:device:generic")
    XCTAssertEqual(device.controls, [
      .init(href: "http://10.0.0.5:8080/x-nmos/connection/v1.1/", type: "urn:x-nmos:control:sr-ctrl/v1.1"),
      .init(href: "ws://10.0.0.5:8080/x-nmos/ncp/v1.0", type: "urn:x-nmos:control:ncp/v1.0"),
    ])
  }

  @OcaDevice
  func testDescribesTheClocksTheEndpointsAreTimedFrom() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()

    let nodeValue = await store.node
    let node = try XCTUnwrap(nodeValue)
    // ordered by object number: the media clock with a PTP time source was made first
    XCTAssertEqual(node.clocks, [
      .ptp(name: "clk0", traceable: false, gmid: "00-1d-c1-ff-fe-12-34-56", locked: true),
      .internal(name: "clk1"),
    ])

    transports.timeSource.syncStatus = .unsynchronized
    await bridge.describe()
    let unlocked = await store.node
    XCTAssertEqual(unlocked?.clocks.first, .ptp(name: "clk0", traceable: false, gmid: "00-1d-c1-ff-fe-12-34-56", locked: false))
    XCTAssertGreaterThan(try XCTUnwrap(unlocked?.version), node.version)
  }

  func testReadsAGrandmasterIDHoweverItIsWritten() {
    let expected = "00-1d-c1-ff-fe-12-34-56"
    XCTAssertEqual(NMOSOcaBridge.grandmasterID(in: "00:1D:C1:FF:FE:12:34:56:0"), expected)
    XCTAssertEqual(NMOSOcaBridge.grandmasterID(in: "00-1d-c1-ff-fe-12-34-56"), expected)
    XCTAssertEqual(NMOSOcaBridge.grandmasterID(in: "0x001DC1FFFE123456"), expected)
    XCTAssertEqual(NMOSOcaBridge.grandmasterID(in: "001dc1fffe123456:127"), expected)
    XCTAssertNil(NMOSOcaBridge.grandmasterID(in: ""))
    XCTAssertNil(NMOSOcaBridge.grandmasterID(in: "00:1D:C1"))
    XCTAssertNil(NMOSOcaBridge.grandmasterID(in: "00:00:00:00:00:00:00:00"))
  }

  func testWritesAMACAddressAsIS04Does() {
    // resource IDs are seeded from this text, so its form must not change
    XCTAssertEqual(OcaMacAddress((0x00, 0x22, 0x97, 0x0A, 0xBB, 0xCC)).nmosString, "00-22-97-0a-bb-cc")
    XCTAssertEqual(
      NMOSOcaResourceIDs(seed: OcaMacAddress((0x00, 0x22, 0x97, 0x01, 0x02, 0x03)).nmosString),
      NMOSOcaResourceIDs(seed: "00-22-97-01-02-03")
    )
  }

  func testTellsMulticastFromUnicast() {
    XCTAssertTrue(MediaStreamSDP.isMulticast("239.69.1.2"))
    XCTAssertFalse(MediaStreamSDP.isMulticast("10.0.0.5"))
    XCTAssertTrue(MediaStreamSDP.isMulticast("ff3e::1"))
    XCTAssertFalse(MediaStreamSDP.isMulticast("fe80::1"))
    XCTAssertEqual(NMOSOcaBridge.bitDepth(of: "audio/L24"), 24)
    XCTAssertNil(NMOSOcaBridge.bitDepth(of: "audio/opus"))
  }

  @OcaDevice
  func testAnRTPSenderWithoutACastModeIsClassifiedByItsDestination() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    let ids = NMOSOcaResourceIDs(seed: host().seed)
    let id = ids.id(.sender, application: transports.aes67.objectNumber, endpoint: 1001)

    var endpoint = try XCTUnwrap(transports.aes67.endpoints.first { $0.idInternal == 1001 })
    endpoint.streamCastMode = .none
    for (destination, transport) in [
      ("10.0.0.9", "urn:x-nmos:transport:rtp.ucast"), ("239.69.1.2", "urn:x-nmos:transport:rtp.mcast"),
      ("", "urn:x-nmos:transport:rtp"),
    ] {
      endpoint.adaptationData = try Aes67EndpointAdaptationData(
        ipParameters: [.init(networkAssignmentID: 1, destinationAddress: destination)]
      ).blob
      try transports.aes67.update(endpoint: endpoint)
      await bridge.describe()
      let senders = await store.senders
      XCTAssertEqual(senders.first { $0.id == id }?.transport, transport, destination)
    }
  }

  @OcaDevice
  func testAnInterfaceTheHostDoesNotNameIsListedOnlyIfItGivesItsAddress() async throws {
    let transports = try await TestTransports()
    let device = OcaDevice.shared
    let avb = try await SwiftOCADevice.OcaNetworkInterface(role: TestTransports.role("AVB"), deviceDelegate: device)
    avb.systemIOInterfaceName = "avb0"
    avb.adaptationIdentifier = MilanAdaptation.identifier
    avb.currentAdaptationData = try MilanNetworkInterfaceAdaptationData(
      timeSourceONo: OcaInvalidONo, macAddress: OcaMacAddress((0x00, 0x22, 0x97, 0xAA, 0xBB, 0xCC))
    ).blob
    let anonymous = try await SwiftOCADevice.OcaNetworkInterface(role: TestTransports.role("IP"), deviceDelegate: device)
    anonymous.systemIOInterfaceName = "dante0"
    transports.manager.networkInterfaces = [transports.interface, avb, anonymous]
    transports.milan.networkInterfaceAssignments = [
      .init(id: 1, networkInterfaceONo: avb.objectNumber, networkBindingParameters: OcaBlob(),
            securityKeyIdentities: [], advertisingMechanisms: []),
      .init(id: 2, networkInterfaceONo: anonymous.objectNumber, networkBindingParameters: OcaBlob(),
            securityKeyIdentities: [], advertisingMechanisms: []),
    ]

    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()

    let node = await store.node
    XCTAssertEqual(node?.interfaces, [
      .init(name: "lan0", chassisID: nil, portID: "00-22-97-01-02-03"),
      .init(name: "avb0", chassisID: nil, portID: "00-22-97-aa-bb-cc"),
    ])
    // a binding may only name an interface the node lists
    let ids = NMOSOcaResourceIDs(seed: host().seed)
    let receivers = await store.receivers
    let receiver = receivers.first { $0.id == ids.id(.receiver, application: transports.milan.objectNumber, endpoint: 1) }
    XCTAssertEqual(receiver?.interfaceBindings, ["avb0"])
  }

  @OcaDevice
  func testObservesEndpointsAndChangesOnlyWhatChanged() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    let ids = NMOSOcaResourceIDs(seed: host().seed)
    let application = transports.aes67.objectNumber
    let senderID = ids.id(.sender, application: application, endpoint: 1001)
    let receiverID = ids.id(.receiver, application: application, endpoint: 1)

    let running = Task { try await bridge.run() }
    defer { running.cancel() }
    try await waitFor("the receiver is described") { await store.resource(.receiver, id: receiverID) != nil }
    let before = await store.resource(.receiver, id: receiverID)
    let senderBefore = await store.resource(.sender, id: senderID)

    // another controller subscribes the receiver, which shows in its adaptation data
    var subscribed = try transports.aes67.endpoint(1)
    subscribed.adaptationData = try Aes67EndpointAdaptationData(activeSDP: TestTransports.stream).blob
    try transports.aes67.update(endpoint: subscribed)
    try await waitFor("the receiver is active") {
      await store.receivers.first { $0.id == receiverID }?.subscription.active == true
    }
    let after = await store.resource(.receiver, id: receiverID)
    XCTAssertGreaterThan(try XCTUnwrap(after?.version), try XCTUnwrap(before?.version))
    let senderAfter = await store.resource(.sender, id: senderID)
    XCTAssertEqual(senderAfter?.version, senderBefore?.version)

    // a time source that loses lock is observed too, though no endpoint changed
    transports.timeSource.syncStatus = .synchronizing
    try await waitFor("the clock is unlocked") {
      await store.node?.clocks.first == .ptp(name: "clk0", traceable: false, gmid: "00-1d-c1-ff-fe-12-34-56", locked: false)
    }

    transports.aes67.remove(endpointID: 1001)
    try await waitFor("the sender is gone") { await store.resource(.sender, id: senderID) == nil }
    let source = await store.resource(.source, id: ids.id(.source, application: application, endpoint: 1001))
    XCTAssertNil(source)
    let flow = await store.resource(.flow, id: ids.id(.flow, application: application, endpoint: 1001))
    XCTAssertNil(flow)
  }

  @OcaDevice
  func testTheDeviceListsNoSendersOrReceiversAndDoesNotChangeWhenTheyDo() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()
    let ids = NMOSOcaResourceIDs(seed: host().seed)

    // the device has senders and receivers, found by their device_id
    let senders = await store.senders
    let receivers = await store.receivers
    XCTAssertFalse(senders.isEmpty)
    XCTAssertFalse(receivers.isEmpty)
    XCTAssertTrue(senders.allSatisfy { $0.deviceID == ids.device })
    XCTAssertTrue(receivers.allSatisfy { $0.deviceID == ids.device })

    // IS-04 deprecates the device's own lists; the schema requires them, so they are empty
    let described = await store.resource(.device, id: ids.device)
    let device = try XCTUnwrap(described)
    let json = try NMOSJSONValue(encoding: device)
    XCTAssertEqual(json["senders"], [])
    XCTAssertEqual(json["receivers"], [])

    transports.aes67.remove(endpointID: 1001)
    transports.dante.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 2, direction: .input))
    await bridge.describe()
    let sendersAfter = await store.senders
    XCTAssertEqual(sendersAfter.count, senders.count - 1)
    let after = await store.resource(.device, id: ids.device)
    XCTAssertEqual(after?.version, device.version)
    XCTAssertEqual(try NMOSJSONValue(encoding: after)["senders"], [])
    XCTAssertEqual(try NMOSJSONValue(encoding: after)["receivers"], [])
  }

  @OcaDevice
  func testLeavesTheSubscriptionToTheConnectionAPIOnceItManagesThem() async throws {
    let transports = try await TestTransports()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host() }
    await bridge.describe()
    let ids = NMOSOcaResourceIDs(seed: host().seed)
    let receiverID = ids.id(.receiver, application: transports.dante.objectNumber, endpoint: 1)
    let peer = NMOSID(UUID())

    // as the Connection API does when it starts, and then on an activation
    await store.manageSubscriptions()
    await store.setSubscription(.receiver, id: receiverID, active: true, peer: peer)

    await bridge.describe()
    let kept = await store.receivers.first { $0.id == receiverID }
    XCTAssertEqual(kept?.subscription, .init(senderID: peer, active: true))

    // describing the rest of the receiver again does not touch what it is connected to,
    // even though the description, read on its own, would now say it is not
    let dante = try XCTUnwrap(transports.dante as? SwiftOCADevice.DanteOcaMediaTransportApplication)
    dante.channelEndpoints[1] = OcaChannelEndpoint(idExternal: OcaBlob("01".utf8), direction: .input)
    var relabelled = try transports.dante.endpoint(1)
    relabelled.userLabel = "Kick drum"
    try transports.dante.update(endpoint: relabelled)
    await bridge.describe()
    let described = await store.receivers.first { $0.id == receiverID }
    XCTAssertEqual(described?.label, "Kick drum")
    XCTAssertEqual(described?.subscription, .init(senderID: peer, active: true))
  }
}
