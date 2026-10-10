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

/// An AES67 application as a device implements it: an endpoint configured from a
/// description then reports that description as its active one.
final class TestAes67Application: SwiftOCADevice.Aes67OcaMediaTransportApplication {
  var configured = [(id: OcaMediaStreamEndpointID, sdp: OcaSDPString, streamID: OcaUint16)]()
  var refusal: OcaStatus?

  override func configureEndpointFromSDP(
    endpointID id: OcaMediaStreamEndpointID,
    sdpString: OcaSDPString,
    streamID: OcaUint16,
    from controller: any OcaController
  ) async throws {
    if let refusal { throw Ocp1Error.status(refusal) }
    configured.append((id, sdpString, streamID))
    try setActiveSDP(sdpString, endpoint: id)
  }

  /// What the device would do on being patched by another controller.
  func setActiveSDP(_ sdp: OcaSDPString, endpoint id: OcaMediaStreamEndpointID) throws {
    var endpoint = try endpoint(id)
    var data = (try? endpoint.adaptationData.decode(Aes67EndpointAdaptationData.self))
      ?? Aes67EndpointAdaptationData()
    data.activeSDP = sdp
    endpoint.adaptationData = try data.blob
    try update(endpoint: endpoint)
  }
}

/// A Dante application whose even-numbered channels are carried by AES67 flows, which
/// it describes and takes as SDP.
final class TestDanteAes67Application: SwiftOCADevice.DanteOcaMediaTransportApplication,
  MediaStreamEndpointSDPRepresentable
{
  var active = [OcaMediaStreamEndpointID: OcaSDPString]()

  func getActiveSDP(_ id: OcaMediaStreamEndpointID) async throws -> OcaSDPString { active[id] ?? "" }

  func configureEndpointFromSDP(
    endpointID id: OcaMediaStreamEndpointID,
    sdpString: OcaSDPString,
    streamID: OcaUint16,
    from controller: any OcaController
  ) async throws {
    active[id] = sdpString
  }

  func usesSessionDescription(_ id: OcaMediaStreamEndpointID) async -> Bool { id % 2 == 0 }
}

final class RTPConnectionTests: XCTestCase {
  private static let multicast = """
  v=0\r\no=- 1311738121 1311738121 IN IP4 192.168.1.1\r\ns=Stage left I/O\r\nc=IN IP4 239.0.0.1/32\r\n\
  t=0 0\r\nm=audio 5004 RTP/AVP 96\r\na=rtpmap:96 L24/48000/8\r\na=sendonly\r\na=ptime:1\r\n\
  a=ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0\r\na=mediaclk:direct=963214424\r\n
  """

  private static let sourceSpecific = """
  v=0\r\no=- 1497010742 1497010742 IN IP4 172.29.26.24\r\ns=SDP Example\r\nt=0 0\r\n\
  m=audio 5000 RTP/AVP 97\r\nc=IN IP4 232.21.21.133/32\r\n\
  a=source-filter: incl IN IP4 232.21.21.133 172.29.226.24\r\na=rtpmap:97 L24/48000/2\r\n
  """

  private static let mode = OcaMediaStreamMode(
    frameFormat: .rtp, encodingType: "audio/L24", samplingRate: 48000, channelCount: 8, packetTime: 1e-3
  )

  @OcaDevice
  private func makeApplication() async throws -> TestAes67Application {
    _ = try await TestDevice.networkManager()
    let application = try await TestAes67Application(
      role: TestDevice.role("Aes67"), deviceDelegate: OcaDevice.shared
    )
    application.networkInterfaceAssignments = try await [TestDevice.interfaceAssignment(address: "192.168.1.20")]
    application.insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: 1, direction: .input, userLabel: "Rx 1", currentStreamMode: Self.mode
    ))
    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1001, direction: .output, userLabel: "Tx 1"))
    try application.setActiveSDP(Self.multicast, endpoint: 1001)
    return application
  }

  @OcaDevice
  func testAnUnconfiguredReceiverPresentsDefaults() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(stack.id(application, 1))"

    let type = try await stack.send(.GET, "\(path)/transporttype")
    XCTAssertEqual(type.json, "urn:x-nmos:transport:rtp")
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
    XCTAssertEqual(active.json?["transport_params"], [[
      "source_ip": .null, "multicast_ip": .null, "interface_ip": "192.168.1.20",
      "destination_port": 5004, "rtp_enabled": true,
    ]])
    // the interface is constrained to the addresses the application is assigned
    let constraints = try await stack.send(.GET, "\(path)/constraints")
    XCTAssertEqual(constraints.json, [[
      "source_ip": [:], "multicast_ip": [:], "destination_port": [:], "rtp_enabled": ["enum": [true]],
      "interface_ip": ["enum": ["192.168.1.20"]],
    ]])
  }

  @OcaDevice
  func testASenderIsDescribedByItsActiveDescriptionAndCannotBeChanged() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "senders/\(stack.id(application, 1001))"

    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"], [[
      "source_ip": "192.168.1.1", "destination_ip": "239.0.0.1", "source_port": 5004,
      "destination_port": 5004, "rtp_enabled": true,
    ]])
    let file = try await stack.send(.GET, "\(path)/transportfile")
    XCTAssertEqual(file.response.headers[.contentType], "application/sdp")
    let body = try await file.response.bodyData
    XCTAssertEqual(String(decoding: body, as: UTF8.self), Self.multicast)

    // every parameter is pinned to what the sender is doing
    let constraints = try await stack.send(.GET, "\(path)/constraints")
    XCTAssertEqual(constraints.json?.arrayValue?.first?["destination_ip"], ["enum": ["239.0.0.1"]])
    let moved = try await stack.send(.PATCH, "\(path)/staged", ["transport_params": [["destination_ip": "239.0.0.2"]]])
    XCTAssertEqual(moved.status, .badRequest)
    let disabled = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": false, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(disabled.status, .badRequest)
    // re-activating what it is already doing is allowed
    let same = try await stack.send(.PATCH, "\(path)/staged", [
      "transport_params": [["destination_ip": "239.0.0.1"]], "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(same.status, .ok)
    XCTAssertTrue(application.configured.isEmpty)
  }

  @OcaDevice
  func testATransportFileIsPassedToConfigureEndpointFromSDP() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(stack.id(application, 1))"

    let staged = try await stack.send(.PATCH, "\(path)/staged", [
      "transport_file": ["data": .string(Self.sourceSpecific), "type": "application/sdp"],
    ])
    XCTAssertEqual(staged.status, .ok)
    // staging shows what the file says, as IS-05 has a receiver that parsed it do
    XCTAssertEqual(staged.json?["transport_params"], [[
      "source_ip": "172.29.226.24", "multicast_ip": "232.21.21.133", "interface_ip": "auto",
      "destination_port": 5000, "rtp_enabled": true,
    ]])
    XCTAssertTrue(application.configured.isEmpty)

    let activated = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(activated.status, .ok)
    XCTAssertEqual(application.configured.count, 1)
    XCTAssertEqual(application.configured.first?.id, 1)
    // the device is given the description exactly as the sender published it
    XCTAssertEqual(application.configured.first?.sdp, Self.sourceSpecific)
    XCTAssertEqual(application.configured.first?.streamID, 5000)

    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"], [[
      "source_ip": "172.29.226.24", "multicast_ip": "232.21.21.133", "interface_ip": "192.168.1.20",
      "destination_port": 5000, "rtp_enabled": true,
    ]])
    XCTAssertEqual(active.json?["transport_file"]?["type"], "application/sdp")
  }

  func testEveryMediaAttributeIsRead() throws {
    let text = """
    v=0\r\no=- 1 1 IN IP4 172.29.26.24\r\ns=Attributes\r\nt=0 0\r\n\
    m=audio 5004 RTP/AVP 96\r\nc=IN IP4 239.69.1.2/32\r\na=recvonly\r\n\
    a=rtpmap:96 L16/96000/4\r\na=ptime:0.125\r\n\
    a=ts-refclk:ptp=IEEE1588-2008:00-1D-C1-FF-FE-12-34-56:7\r\na=mediaclk:direct=42\r\n\
    a=source-filter: incl IN IP4 239.69.1.2 10.0.0.9\r\n
    """
    let sdp = try XCTUnwrap(MediaStreamSDP(sdpString: text))
    XCTAssertEqual(sdp.sampleSize, 16)
    XCTAssertEqual(sdp.sampleRate, 96000)
    XCTAssertEqual(sdp.channelCount, 4)
    XCTAssertEqual(sdp.packetTime, 125e-6)
    XCTAssertEqual(sdp.ptpGrandmasterID, "00-1D-C1-FF-FE-12-34-56")
    XCTAssertEqual(sdp.ptpDomain, 7)
    XCTAssertEqual(sdp.mediaClockOffset, 42)
    XCTAssertEqual(sdp.sourceAddress, "10.0.0.9")
    XCTAssertEqual(sdp.direction, .receiveOnly)
  }

  @OcaDevice
  func testParametersTakePrecedenceOverTheTransportFile() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let result = try await stack.send(.PATCH, "receivers/\(stack.id(application, 1))/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.sourceSpecific), "type": "application/sdp"],
      "transport_params": [["multicast_ip": "232.20.44.7", "destination_port": 6000]],
    ])
    XCTAssertEqual(result.status, .ok)
    let sdp = try XCTUnwrap(MediaStreamSDP(sdpString: XCTUnwrap(application.configured.first?.sdp)))
    XCTAssertEqual(sdp.destinationAddress, "232.20.44.7")
    XCTAssertEqual(sdp.destinationPort, 6000)
    XCTAssertEqual(application.configured.first?.streamID, 6000)
    // what the parameters did not contradict is still the file's
    XCTAssertEqual(sdp.sourceAddress, "172.29.226.24")
    XCTAssertEqual(sdp.channelCount, 2)
    XCTAssertEqual(sdp.sessionName, "SDP Example")
  }

  @OcaDevice
  func testParametersAloneAreMadeIntoADescription() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let result = try await stack.send(.PATCH, "receivers/\(stack.id(application, 1))/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["multicast_ip": "239.10.20.30", "destination_port": 5006, "interface_ip": "auto"]],
    ])
    XCTAssertEqual(result.status, .ok)
    // the stream is expected in the mode the endpoint is in
    let sdp = try XCTUnwrap(MediaStreamSDP(sdpString: XCTUnwrap(application.configured.first?.sdp)))
    XCTAssertEqual(sdp.destinationAddress, "239.10.20.30")
    XCTAssertEqual(sdp.destinationPort, 5006)
    XCTAssertEqual(sdp.sampleSize, 24)
    XCTAssertEqual(sdp.sampleRate, 48000)
    XCTAssertEqual(sdp.channelCount, 8)
    XCTAssertEqual(sdp.direction, .receiveOnly)

    // a unicast stream is addressed to the receiver's own interface
    let unicast = try await stack.send(.PATCH, "receivers/\(stack.id(application, 1))/staged", [
      "activation": ["mode": "activate_immediate"],
      "transport_params": [["multicast_ip": .null, "interface_ip": "192.168.1.20"]],
    ])
    XCTAssertEqual(unicast.status, .ok)
    let second = try XCTUnwrap(MediaStreamSDP(sdpString: XCTUnwrap(application.configured.last?.sdp)))
    XCTAssertEqual(second.destinationAddress, "192.168.1.20")
    XCTAssertFalse(second.isMulticast)
  }

  @OcaDevice
  func testDisablingAReceiverClearsItsSubscription() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(stack.id(application, 1))"
    _ = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ])
    let disabled = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": false, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(disabled.status, .ok)
    XCTAssertEqual(application.configured.last?.sdp, "")
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
  }

  @OcaDevice
  func testFilesAndFailuresTheDeviceRefuses() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(stack.id(application, 1))/staged"

    // video is not something an audio receiver can be staged with
    let video = "v=0\r\no=- 1 1 IN IP4 10.0.0.1\r\ns=x\r\nc=IN IP4 239.1.1.1/32\r\nt=0 0\r\nm=video 5000 RTP/AVP 96\r\na=rtpmap:96 raw/90000\r\n"
    for file: NMOSJSONValue in [
      ["data": .string(video), "type": "application/sdp"],
      ["data": .string(Self.multicast), "type": "application/json"],
    ] {
      let result = try await stack.send(.PATCH, path, ["transport_file": file])
      XCTAssertEqual(result.status, .badRequest, "\(file)")
    }

    let patch: NMOSJSONValue = [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ]
    application.refusal = .parameterError
    let refused = try await stack.send(.PATCH, path, patch)
    XCTAssertEqual(refused.status, .badRequest)
    application.refusal = .deviceError
    let failed = try await stack.send(.PATCH, path, patch)
    XCTAssertEqual(failed.status, .internalServerError)
    XCTAssertEqual(failed.json?["code"], 500)
  }

  @OcaDevice
  func testAChangeMadeThroughOCAReachesActiveAndIS04() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let receiver = stack.id(application, 1)
    await stack.store.upsert(.receiver(.init(
      id: receiver, label: "Rx 1", description: "", deviceID: ConnectionStack.ids.device,
      transport: "urn:x-nmos:transport:rtp", interfaceBindings: [], subscription: .init(active: false)
    )))

    // another controller patches the receiver with AES70-21 ConfigureEndpointFromSDP
    try await application.configureEndpointFromSDP(endpointID: 1, sdpString: Self.multicast, streamID: 0, from: TestController())
    let active = try await stack.wait(for: "receivers/\(receiver)/active") { $0["master_enable"] == true }
    XCTAssertEqual(active?["transport_params"]?.arrayValue?.first?["multicast_ip"], "239.0.0.1")
    XCTAssertEqual(active?["sender_id"], .null)

    for _ in 0..<300 {
      if case let .receiver(resource) = await stack.store.resource(.receiver, id: receiver),
         resource.subscription.active { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard case let .receiver(resource) = await stack.store.resource(.receiver, id: receiver) else {
      return XCTFail("the receiver has gone")
    }
    XCTAssertEqual(resource.subscription, .init(senderID: nil, active: true))
    // what is staged follows, so the next PATCH starts from what the receiver is doing
    let staged = try await stack.parameters("receivers/\(receiver)/staged")
    XCTAssertEqual(staged?["multicast_ip"], "239.0.0.1")
  }

  @OcaDevice
  func testDescribingTheDeviceAgainDoesNotWriteOverAConnection() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let bridge = stack.bridge
    await bridge.describe()
    let receiver = stack.id(application, 1)
    let peer = NMOSID(UUID(version5: "peer", namespace: NMOSOcaResourceIDs.namespace))

    let patched = try await stack.send(.PATCH, "receivers/\(receiver)/staged", [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ])
    XCTAssertEqual(patched.status, .ok)
    let connected = await stack.store.receivers.first { $0.id == receiver }
    XCTAssertEqual(connected?.subscription, .init(senderID: peer, active: true))

    // the stream has yet to arrive, so the endpoint is subscribed without being connected;
    // IS-04 says what IS-05 does, and the bridge leaves the sender the client named
    XCTAssertEqual(application.endpointStatuses[1]?.state, .notReady)
    var relabelled = try application.endpoint(1)
    relabelled.userLabel = "Stage left"
    try application.update(endpoint: relabelled)
    await bridge.describe()
    let described = await stack.store.receivers.first { $0.id == receiver }
    XCTAssertEqual(described?.label, "Stage left")
    XCTAssertEqual(described?.subscription, .init(senderID: peer, active: true))
    let active = try await stack.send(.GET, "receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["master_enable"], true)

    // unsubscribed by another controller: the Connection API clears it, and a bridge
    // describing the device at the same time agrees with it
    try await application.configureEndpointFromSDP(endpointID: 1, sdpString: "", streamID: 0, from: TestController())
    await bridge.describe()
    for _ in 0..<300 {
      if await stack.store.receivers.first(where: { $0.id == receiver })?.subscription.active == false { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let cleared = await stack.store.receivers.first { $0.id == receiver }
    XCTAssertEqual(cleared?.subscription, .init(senderID: nil, active: false))
  }

  @OcaDevice
  func testAReceiverStagedWithItsSecondInterfaceKeepsTheSenderTheClientNamed() async throws {
    let application = try await makeApplication()
    application.networkInterfaceAssignments = try await [
      TestDevice.interfaceAssignment(address: "192.168.1.20"),
      TestDevice.interfaceAssignment(address: "192.168.2.20"),
    ]
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(stack.id(application, 1))"
    let peer = NMOSID(UUID(version5: "peer", namespace: NMOSOcaResourceIDs.namespace))
    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
      "transport_params": [["interface_ip": "192.168.2.20"]],
    ])
    XCTAssertEqual(result.status, .ok)
    // a multicast description does not say which interface the receiver joined on
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["sender_id"], .string(peer.description))
  }

  @OcaDevice
  func testDanteChannelsCarriedByAES67FlowsArePatchedAsRTP() async throws {
    _ = try await TestDevice.networkManager()
    let application = try await TestDanteAes67Application(
      role: TestDevice.role("DanteAes67"), deviceDelegate: OcaDevice.shared
    )
    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input))
    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 2, direction: .input, currentStreamMode: Self.mode))
    let stack = try await ConnectionStack([application])

    let native = try await stack.send(.GET, "receivers/\(stack.id(application, 1))/transporttype")
    XCTAssertEqual(native.json, "urn:x-nmos:transport:dante")
    let path = "receivers/\(stack.id(application, 2))"
    let rtp = try await stack.send(.GET, "\(path)/transporttype")
    XCTAssertEqual(rtp.json, "urn:x-nmos:transport:rtp")

    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(application.active[2], Self.multicast)
    let active = try await stack.parameters("\(path)/active")
    XCTAssertEqual(active?["multicast_ip"], "239.0.0.1")
    XCTAssertEqual(active?["destination_port"], 5004)
    // an application assigned no interface receives on the host's, so `auto` is resolved
    XCTAssertNotEqual(active?["interface_ip"], "auto")
  }
}
