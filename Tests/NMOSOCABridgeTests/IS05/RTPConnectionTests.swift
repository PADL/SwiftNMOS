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

/// An AES67 application as a device implements it (AES70-21 §10.2.4): an endpoint
/// configured from a description reports it as its active one and is Ready, Start runs
/// it, Stop leaves it Ready, and an empty description leaves it NotReady. Configuring a
/// running endpoint with the description it runs keeps it running. A `startsOnConfigure`
/// one runs on being configured, and a `lateStatus` one reports a command's status only
/// after a moment.
final class TestAes67Application: SwiftOCADevice.Aes67OcaMediaTransportApplication {
  var configured = [(
    id: OcaMediaStreamEndpointID,
    sdp: OcaSDPString,
    mediaIDType: Aes67MediaIDType,
    mediaID: OcaString
  )]()
  var commands = [(id: OcaMediaStreamEndpointID, command: OcaMediaStreamEndpointCommand)]()
  var refusal: OcaStatus?
  var startRefusal: OcaStatus?
  /// Refuses the next start only.
  var nextStartRefusal: OcaStatus?
  var stopRefusal: OcaStatus?
  var startsOnConfigure = false
  var lateStatus = false

  override func configureEndpointFromSDP(
    endpointID id: OcaMediaStreamEndpointID,
    sdpString: OcaSDPString,
    mediaIDType: Aes67MediaIDType,
    mediaID: OcaString,
    from controller: any OcaController
  ) async throws {
    if let refusal { throw Ocp1Error.status(refusal) }
    configured.append((id, sdpString, mediaIDType, mediaID))
    let data = try? endpoint(id).adaptationData.decode(Aes67EndpointAdaptationData.self)
    let same = data?.activeSDP == sdpString && data?.mediaIDType == mediaIDType && data?.mediaID == mediaID
    try setActiveSDP(sdpString, endpoint: id, mediaIDType: mediaIDType, mediaID: mediaID)
    if same, endpointStatuses[id]?.state == .running { return }
    update(endpointID: id, status: .init(state: sdpString.isEmpty ? .notReady : startsOnConfigure ? .running : .ready))
  }

  override func applyEndpointCommand(
    endpointID id: OcaMediaStreamEndpointID,
    command: OcaMediaStreamEndpointCommand,
    from controller: any OcaController
  ) async throws {
    guard try endpoint(id).direction == .input else {
      return try await super.applyEndpointCommand(endpointID: id, command: command, from: controller)
    }
    let starts = command == .start || command == .connectAndStart
    if let startRefusal, starts { throw Ocp1Error.status(startRefusal) }
    if let refusal = nextStartRefusal, starts {
      nextStartRefusal = nil
      throw Ocp1Error.status(refusal)
    }
    if let stopRefusal, command == .stop { throw Ocp1Error.status(stopRefusal) }
    commands.append((id, command))
    let status = OcaMediaStreamEndpointStatus(state: starts ? .running : .ready)
    guard lateStatus else { return update(endpointID: id, status: status) }
    Task { @OcaDevice in
      try await Task.sleep(for: .milliseconds(200))
      self.update(endpointID: id, status: status)
    }
  }

  /// What the device would do on being patched by another controller.
  func setActiveSDP(
    _ sdp: OcaSDPString,
    endpoint id: OcaMediaStreamEndpointID,
    mediaIDType: Aes67MediaIDType = .none,
    mediaID: OcaString = ""
  ) throws {
    var endpoint = try endpoint(id)
    var data = (try? endpoint.adaptationData.decode(Aes67EndpointAdaptationData.self))
      ?? Aes67EndpointAdaptationData()
    data.activeSDP = sdp
    data.mediaIDType = mediaIDType
    data.mediaID = mediaID
    endpoint.adaptationData = try data.blob
    try update(endpoint: endpoint)
  }
}

/// A Dante application whose even-numbered channels are carried by AES67 flows, which
/// it describes and accepts as SDP: a description configured on a channel is received once
/// Start applies it.
final class TestDanteAes67Application: SwiftOCADevice.DanteOcaMediaTransportApplication,
  MediaStreamEndpointSDPRepresentable
{
  var configuredSDPs = [OcaMediaStreamEndpointID: OcaSDPString]()
  var active = [OcaMediaStreamEndpointID: OcaSDPString]()

  func getActiveSDP(_ id: OcaMediaStreamEndpointID) async throws -> OcaSDPString { active[id] ?? "" }

  func configureEndpointFromSDP(
    endpointID id: OcaMediaStreamEndpointID,
    sdpString: OcaSDPString,
    mediaIDType: Aes67MediaIDType,
    mediaID: OcaString,
    from controller: any OcaController
  ) async throws {
    configuredSDPs[id] = sdpString
    active[id] = nil
  }

  override func applyEndpointCommand(
    endpointID id: OcaMediaStreamEndpointID,
    command: OcaMediaStreamEndpointCommand,
    from controller: any OcaController
  ) async throws {
    switch command {
    case .start, .connectAndStart:
      guard let sdp = configuredSDPs[id] else { throw Ocp1Error.status(.invalidRequest) }
      active[id] = sdp
    case .stop:
      active[id] = nil
    default:
      throw Ocp1Error.status(.notImplemented)
    }
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
    let path = "receivers/\(await stack.id(application, 1))"

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
    let path = "senders/\(await stack.id(application, 1001))"

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
    // an application that cannot stop its senders refuses, as IS-05 has a request that
    // meets the schema and constraints but cannot be carried out refused
    XCTAssertEqual(disabled.status, .internalServerError)
    // re-activating what it is already doing is allowed
    let same = try await stack.send(.PATCH, "\(path)/staged", [
      "transport_params": [["destination_ip": "239.0.0.1"]], "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(same.status, .ok)
    XCTAssertTrue(application.configured.isEmpty)
  }

  /// A sender is disabled while Ready, which is where a device leaves one it has not
  /// started; Connected counts as enabled, as a started sender may wait there for media.
  @OcaDevice
  func testASenderIsDisabledWhileReady() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "senders/\(await stack.id(application, 1001))"
    application.update(endpointID: 1001, status: .init(state: .ready))
    let ready = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(ready.json?["master_enable"], false)
    application.update(endpointID: 1001, status: .init(state: .connected))
    let connected = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(connected.json?["master_enable"], true)
  }

  @OcaDevice
  func testATransportFileIsPassedToConfigureEndpointFromSDP() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"

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
    // configured, then started (AES70-21 §10.2.4)
    XCTAssertEqual(application.commands.map(\.command), [.connectAndStart])
    XCTAssertEqual(application.endpointStatuses[1]?.state, .running)
    // the device is given the description exactly as the sender published it
    XCTAssertEqual(application.configured.first?.sdp, Self.sourceSpecific)
    // a single media description needs no identifier (AES70-21 §10.2.4)
    XCTAssertEqual(application.configured.first?.mediaIDType, Aes67MediaIDType.none)

    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"], [[
      "source_ip": "172.29.226.24", "multicast_ip": "232.21.21.133", "interface_ip": "192.168.1.20",
      "destination_port": 5000, "rtp_enabled": true,
    ]])
    XCTAssertEqual(active.json?["transport_file"]?["type"], "application/sdp")
  }

  @OcaDevice
  func testATransportFileStreamIsNamedByItsMid() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    // an ST 2022-7 pair: the receiver takes the first leg, named by its a=mid
    let leg = Self.sourceSpecific.components(separatedBy: "m=audio")
    let file = leg[0] + "m=audio" + leg[1] + "a=mid:primary\r\n" + "m=audio" + leg[1] + "a=mid:secondary\r\n"
    let result = try await stack.send(.PATCH, "receivers/\(await stack.id(application, 1))/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(file), "type": "application/sdp"],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(application.configured.first?.sdp, file)
    XCTAssertEqual(application.configured.first?.mediaIDType, .mid)
    XCTAssertEqual(application.configured.first?.mediaID, "primary")
  }

  @OcaDevice
  func testADuplicatedMidIsPassedOverForThePosition() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let leg = Self.sourceSpecific.components(separatedBy: "m=audio")
    let file = leg[0] + "m=audio" + leg[1] + "a=mid:1\r\n" + "m=audio" + leg[1] + "a=mid:1\r\n"
    let result = try await stack.send(.PATCH, "receivers/\(await stack.id(application, 1))/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(file), "type": "application/sdp"],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(application.configured.first?.mediaIDType, .ordinal)
    XCTAssertEqual(application.configured.first?.mediaID, "1")
  }

  @OcaDevice
  func testTheActiveStreamIsTheOneAdaptationDataNames() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let leg = Self.sourceSpecific.components(separatedBy: "m=audio")
    let second = leg[1].replacingOccurrences(of: "232.21.21.133", with: "232.21.21.134")
    let pair = leg[0] + "m=audio" + leg[1] + "a=mid:p\r\n" + "m=audio" + second + "a=mid:s\r\n"
    // another controller selects the second leg
    try application.setActiveSDP(pair, endpoint: 1, mediaIDType: .mid, mediaID: "s")
    let active = try await stack.send(.GET, "receivers/\(await stack.id(application, 1))/active")
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["multicast_ip"], "232.21.21.134")
  }

  @OcaDevice
  func testATransportFileStreamWithoutAMidIsNamedByItsPosition() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let leg = Self.sourceSpecific.components(separatedBy: "m=audio")
    // a first media description that is not linear PCM is passed over
    let file = leg[0] + "m=video 5000 RTP/AVP 96\r\n" + "m=audio" + leg[1]
    let result = try await stack.send(.PATCH, "receivers/\(await stack.id(application, 1))/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(file), "type": "application/sdp"],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(application.configured.first?.mediaIDType, .ordinal)
    XCTAssertEqual(application.configured.first?.mediaID, "2")
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
    let result = try await stack.send(.PATCH, "receivers/\(await stack.id(application, 1))/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.sourceSpecific), "type": "application/sdp"],
      "transport_params": [["multicast_ip": "232.20.44.7", "destination_port": 6000]],
    ])
    XCTAssertEqual(result.status, .ok)
    let sdp = try XCTUnwrap(MediaStreamSDP(sdpString: XCTUnwrap(application.configured.first?.sdp)))
    XCTAssertEqual(sdp.destinationAddress, "232.20.44.7")
    XCTAssertEqual(sdp.destinationPort, 6000)
    XCTAssertEqual(application.configured.first?.mediaIDType, Aes67MediaIDType.none)
    // what the parameters did not contradict is still the file's
    XCTAssertEqual(sdp.sourceAddress, "172.29.226.24")
    XCTAssertEqual(sdp.channelCount, 2)
    XCTAssertEqual(sdp.sessionName, "SDP Example")
  }

  @OcaDevice
  func testParametersAloneAreMadeIntoADescription() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let result = try await stack.send(.PATCH, "receivers/\(await stack.id(application, 1))/staged", [
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
    let unicast = try await stack.send(.PATCH, "receivers/\(await stack.id(application, 1))/staged", [
      "activation": ["mode": "activate_immediate"],
      "transport_params": [["multicast_ip": .null, "interface_ip": "192.168.1.20"]],
    ])
    XCTAssertEqual(unicast.status, .ok)
    let second = try XCTUnwrap(MediaStreamSDP(sdpString: XCTUnwrap(application.configured.last?.sdp)))
    XCTAssertEqual(second.destinationAddress, "192.168.1.20")
    XCTAssertFalse(second.isMulticast)
  }

  @OcaDevice
  private func patch(
    _ stack: ConnectionStack,
    _ path: String,
    _ body: [String: NMOSJSONValue]
  ) async throws -> HTTPStatusCode {
    var body = body
    body["activation"] = ["mode": "activate_immediate"]
    return try await stack.send(.PATCH, "\(path)/staged", .object(body)).status
  }

  @OcaDevice
  private func patchOK(
    _ stack: ConnectionStack,
    _ path: String,
    _ body: [String: NMOSJSONValue],
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let status = try await patch(stack, path, body)
    XCTAssertEqual(status, .ok, file: file, line: line)
  }

  /// With `master_enable` false the receiver is configured and left Ready, not started;
  /// enabling it then starts it without configuring it again.
  @OcaDevice
  func testAReceiverActivatedDisabledIsConfiguredButNotStarted() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    let result = try await patch(stack, path, [
      "master_enable": false, "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ])
    XCTAssertEqual(result, .ok)
    XCTAssertEqual(application.configured.map(\.sdp), [Self.multicast])
    XCTAssertTrue(application.commands.isEmpty)
    XCTAssertEqual(application.endpointStatuses[1]?.state, .ready)
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)

    try await patchOK(stack, path, ["master_enable": true])
    XCTAssertEqual(application.configured.count, 1, "it is Ready on that description already")
    XCTAssertEqual(application.commands.map(\.command), [.connectAndStart])
    let running = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(running.json?["master_enable"], true)
  }

  /// Enabling a receiver that already runs the staged description only sends Start, so the
  /// audio is not interrupted by configuring it again.
  @OcaDevice
  func testReassertingARunningReceiverDoesNotConfigureItAgain() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    let file: NMOSJSONValue = ["data": .string(Self.multicast), "type": "application/sdp"]
    try await patchOK(stack, path, ["master_enable": true, "transport_file": file])
    try await patchOK(stack, path, ["master_enable": true, "transport_file": file])
    XCTAssertEqual(application.configured.count, 1)
    XCTAssertEqual(application.commands.map(\.command), [.connectAndStart], "a running receiver is left as it is")
    XCTAssertEqual(application.endpointStatuses[1]?.state, .running)
  }

  /// Disabling a running receiver whose file is still staged sends Stop and leaves it Ready
  /// on that description; with a new file it is configured too, Ready on the new one.
  @OcaDevice
  func testDisablingARunningReceiverStopsIt() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    try await patchOK(stack, path, [
      "master_enable": true, "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ])
    try await patchOK(stack, path, ["master_enable": false])
    XCTAssertEqual(application.configured.count, 1)
    XCTAssertEqual(application.commands.map(\.command), [.connectAndStart, .stop])
    XCTAssertEqual(application.endpointStatuses[1]?.state, .ready)
    let stopped = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(stopped.json?["master_enable"], false)

    try await patchOK(stack, path, ["master_enable": true])
    try await patchOK(stack, path, [
      "master_enable": false, "transport_file": ["data": .string(Self.sourceSpecific), "type": "application/sdp"],
    ])
    XCTAssertEqual(application.commands.map(\.command), [.connectAndStart, .stop, .connectAndStart, .stop])
    XCTAssertEqual(application.configured.map(\.sdp), [Self.multicast, Self.sourceSpecific])
    XCTAssertEqual(application.endpointStatuses[1]?.state, .ready)
  }

  /// Disabled with parameters but no file, the receiver is configured from them and left
  /// Ready; only with nothing that names a stream is its connection closed.
  @OcaDevice
  func testADisabledReceiverIsConfiguredFromParametersAndClearedByNone() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    try await patchOK(stack, path, [
      "master_enable": false, "transport_params": [["multicast_ip": "239.10.20.30", "destination_port": 5006]],
    ])
    let sdp = try XCTUnwrap(MediaStreamSDP(sdpString: XCTUnwrap(application.configured.last?.sdp)))
    XCTAssertEqual(sdp.destinationAddress, "239.10.20.30")
    XCTAssertEqual(sdp.destinationPort, 5006)
    XCTAssertEqual(application.endpointStatuses[1]?.state, .ready)
    XCTAssertTrue(application.commands.isEmpty)

    try await patchOK(stack, path, [
      "master_enable": false, "transport_file": ["data": .null, "type": .null],
      "transport_params": [["multicast_ip": .null, "source_ip": .null]],
    ])
    XCTAssertEqual(application.configured.last?.sdp, "")
    XCTAssertEqual(application.endpointStatuses[1]?.state, .notReady)
  }

  /// A refused Start fails the activation, which then changes nothing: a receiver that had
  /// no description is configured with none again (NotReady), and `/active` reports it
  /// disabled.
  @OcaDevice
  func testARefusedStartFailsTheActivation() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    application.startRefusal = .deviceError
    let result = try await patch(stack, path, [
      "master_enable": true, "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ])
    XCTAssertEqual(result, .internalServerError)
    XCTAssertEqual(application.configured.map(\.sdp), [Self.multicast, ""])
    XCTAssertEqual(application.endpointStatuses[1]?.state, .notReady)
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
  }

  /// A receiver with no status is not known to run, so it is reported disabled.
  @OcaDevice
  func testAReceiverWithNoStatusIsDisabled() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    try application.setActiveSDP(Self.multicast, endpoint: 1)
    application.endpointStatuses.removeValue(forKey: 1)
    let active = try await stack.send(.GET, "receivers/\(await stack.id(application, 1))/active")
    XCTAssertEqual(active.json?["master_enable"], false)
  }

  @OcaDevice
  func testFilesAndFailuresTheDeviceRefuses() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))/staged"

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
    let receiver = await stack.id(application, 1)
    await stack.store.upsert(.receiver(.init(
      id: receiver, label: "Rx 1", description: "", deviceID: ConnectionStack.ids.device,
      transport: "urn:x-nmos:transport:rtp", interfaceBindings: [], subscription: .init(active: false)
    )))

    // another controller patches the receiver with AES70-21 ConfigureEndpointFromSDP,
    // which leaves it Ready, then starts it
    try await application.configureEndpointFromSDP(endpointID: 1, sdpString: Self.multicast, mediaIDType: .none, mediaID: "", from: TestController())
    let ready = try await stack.send(.GET, "receivers/\(receiver)/active")
    XCTAssertEqual(ready.json?["master_enable"], false)
    try await application.applyEndpointCommand(endpointID: 1, command: .start, from: TestController())
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
    let receiver = await stack.id(application, 1)
    let peer = NMOSID(UUID(version5: "peer", namespace: NMOSOcaResourceIDs.namespace))

    let patched = try await stack.send(.PATCH, "receivers/\(receiver)/staged", [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.multicast), "type": "application/sdp"],
    ])
    XCTAssertEqual(patched.status, .ok)
    let connected = await stack.store.receivers.first { $0.id == receiver }
    XCTAssertEqual(connected?.subscription, .init(senderID: peer, active: true))

    // the endpoint is started; IS-04 says what IS-05 does, and the bridge leaves the sender
    // the client named
    XCTAssertEqual(application.endpointStatuses[1]?.state, .running)
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
    try await application.configureEndpointFromSDP(endpointID: 1, sdpString: "", mediaIDType: .none, mediaID: "", from: TestController())
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
    let path = "receivers/\(await stack.id(application, 1))"
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

    let native = try await stack.send(.GET, "receivers/\(await stack.id(application, 1))/transporttype")
    XCTAssertEqual(native.json, "urn:x-padl:transport:dante")
    let path = "receivers/\(await stack.id(application, 2))"
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

/// The review's cases: devices that do not report what they do, failures that put things
/// back, and what counts as the same description.
extension RTPConnectionTests {
  private static let file: NMOSJSONValue = ["data": .string(multicast), "type": "application/sdp"]
  private static let otherFile: NMOSJSONValue = ["data": .string(sourceSpecific), "type": "application/sdp"]

  @OcaDevice
  private func receiver(_ stack: ConnectionStack, _ application: TestAes67Application) async -> NMOSReceiverResource? {
    let id = await stack.id(application, 1)
    return await stack.store.receivers.first { $0.id == id }
  }

  @OcaDevice
  private func until(_ what: String, _ condition: @OcaDevice () async -> Bool) async throws {
    for _ in 0..<300 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out waiting until \(what)")
  }

  /// A Start refused after the device was configured puts it back: running the description it
  /// had, so the request changes nothing, and `/staged` and `/active` say so.
  @OcaDevice
  func testARefusedStartPutsARunningReceiverBack() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    try await patchOK(stack, path, ["master_enable": true, "transport_file": Self.file])
    application.nextStartRefusal = .locked
    let result = try await patch(stack, path, ["master_enable": true, "transport_file": Self.otherFile])
    XCTAssertEqual(result, .locked)
    XCTAssertEqual(application.configured.map(\.sdp), [Self.multicast, Self.sourceSpecific, Self.multicast])
    XCTAssertEqual(application.endpointStatuses[1]?.state, .running)
    let staged = try await stack.send(.GET, "\(path)/staged")
    XCTAssertEqual(staged.json?["transport_file"]?["data"], .string(Self.multicast))
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["multicast_ip"], "239.0.0.1")
  }

  /// A Start refused on a receiver Ready on another description leaves it Ready on that
  /// one, and IS-04 says it is not active.
  @OcaDevice
  func testARefusedStartLeavesAReadyReceiverReadyAndIS04Inactive() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    try await patchOK(stack, path, ["master_enable": false, "transport_file": Self.file])
    application.startRefusal = .deviceError
    let result = try await patch(stack, path, ["master_enable": true, "transport_file": Self.otherFile])
    XCTAssertEqual(result, .internalServerError)
    XCTAssertEqual(application.configured.last?.sdp, Self.multicast)
    XCTAssertEqual(application.endpointStatuses[1]?.state, .ready)
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["multicast_ip"], "239.0.0.1")
    let resource = await receiver(stack, application)
    XCTAssertEqual(resource?.subscription.active, false)
  }

  /// A disabled receiver that another controller configures shows the new description in
  /// `/active`, not the settings it was disabled with.
  @OcaDevice
  func testADisabledReceiverReconfiguredElsewhereShowsItsNewDescription() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    try await patchOK(stack, path, ["master_enable": false, "transport_file": Self.file])
    try await application.configureEndpointFromSDP(
      endpointID: 1, sdpString: Self.sourceSpecific, mediaIDType: .none, mediaID: "", from: TestController()
    )
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["multicast_ip"], "232.21.21.133")
  }

  /// An unchanged description is configured again unless the receiver is Ready, Connected or
  /// Running on it: one halted, or NotReady with the description kept, is recovered.
  @OcaDevice
  func testAnUnchangedDescriptionRecoversAHaltedReceiver() async throws {
    for state: OcaMediaStreamEndpointState in [.errorHalt, .notReady] {
      let application = try await makeApplication()
      let stack = try await ConnectionStack([application])
      let path = "receivers/\(await stack.id(application, 1))"
      try await patchOK(stack, path, ["master_enable": true, "transport_file": Self.file])
      application.update(endpointID: 1, status: .init(state: state))
      try await patchOK(stack, path, ["master_enable": true, "transport_file": Self.file])
      XCTAssertEqual(application.configured.count, 2, "\(state)")
      XCTAssertEqual(application.commands.map(\.command), [.connectAndStart, .connectAndStart], "\(state)")
      XCTAssertEqual(application.endpointStatuses[1]?.state, .running)
    }
  }

  /// A start or stop made by another controller shows only in an AES67 application's
  /// statuses, which the bridge observes, so IS-04 follows it.
  @OcaDevice
  func testAStartAndStopByAnotherControllerReachIS04() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    try await application.configureEndpointFromSDP(
      endpointID: 1, sdpString: Self.multicast, mediaIDType: .none, mediaID: "", from: TestController()
    )
    try await until("the description is described") {
      await self.receiver(stack, application) != nil
    }
    try await Task.sleep(for: .milliseconds(100))
    let ready = await receiver(stack, application)
    XCTAssertEqual(ready?.subscription.active, false)
    try await application.applyEndpointCommand(endpointID: 1, command: .start, from: TestController())
    try await until("IS-04 says the receiver is active") {
      await self.receiver(stack, application)?.subscription.active == true
    }
    try await application.applyEndpointCommand(endpointID: 1, command: .stop, from: TestController())
    try await until("IS-04 says the receiver is inactive") {
      await self.receiver(stack, application)?.subscription.active == false
    }
  }

  /// What the receiver runs is the same description if only its session's name, information,
  /// origin or direction differ; a different clock reference or media clock is not.
  @OcaDevice
  func testWhatCountsAsTheSameDescription() async throws {
    let cosmetic = Self.multicast
      .replacingOccurrences(of: "o=- 1311738121 1311738121", with: "o=- 1311738121 1311738122")
      .replacingOccurrences(of: "s=Stage left I/O", with: "s=Renamed\r\ni=Moved")
      .replacingOccurrences(of: "a=sendonly", with: "a=recvonly")
    let refclk = Self.multicast.replacingOccurrences(
      of: "a=ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0", with: "a=ts-refclk:localmac=39-A7-94-07-CB-D0"
    )
    let mediaclk = Self.multicast.replacingOccurrences(of: "a=mediaclk:direct=963214424", with: "a=mediaclk:direct=0")
    for (text, reconfigures) in [(cosmetic, false), (refclk, true), (mediaclk, true)] {
      let application = try await makeApplication()
      let stack = try await ConnectionStack([application])
      let path = "receivers/\(await stack.id(application, 1))"
      try await patchOK(stack, path, ["master_enable": true, "transport_file": Self.file])
      try await patchOK(stack, path, [
        "master_enable": true, "transport_file": ["data": .string(text), "type": "application/sdp"],
      ])
      XCTAssertEqual(application.configured.count, reconfigures ? 2 : 1, text)
      XCTAssertEqual(application.commands.count, reconfigures ? 2 : 1, text)
    }
  }

  /// A device that reports its new status only later, as a proxy does, is reported active
  /// by the activation once Start succeeded.
  @OcaDevice
  func testAnActivationIsReportedFromTheCommandsThatSucceeded() async throws {
    let application = try await makeApplication()
    application.lateStatus = true
    let stack = try await ConnectionStack([application])
    let id = await stack.id(application, 1)
    let staged = NMOSConnectionState(
      masterEnable: true, transportParameters: [["multicast_ip": "239.0.0.1", "destination_port": 5004]],
      transportFile: NMOSTransportFile(data: Self.multicast, type: NMOSTransportFile.sdpType)
    )
    let activated = try await stack.bridge.connectionProvider.activate(.receiver, id: id, staged: staged)
    XCTAssertEqual(application.endpointStatuses[1]?.state, .ready, "the status has yet to arrive")
    XCTAssertTrue(activated.masterEnable)
    XCTAssertEqual(activated.transportParameters.first?["multicast_ip"], "239.0.0.1")
    try await until("the status arrives") { application.endpointStatuses[1]?.state == .running }
  }

  /// A receiver is enabled only while Running: Connected without Start, halted, or in an
  /// unknown state, it is not.
  @OcaDevice
  func testAReceiverIsDisabledUnlessRunning() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    try application.setActiveSDP(Self.multicast, endpoint: 1)
    for (state, enabled) in [(OcaMediaStreamEndpointState.connected, false), (.errorHalt, false), (.unknown, false), (.running, true)] {
      application.update(endpointID: 1, status: .init(state: state))
      let active = try await stack.send(.GET, "\(path)/active")
      XCTAssertEqual(active.json?["master_enable"], .bool(enabled), "\(state)")
    }
  }

  /// A refused Start or Stop other than Locked is the device failing (500), not the request.
  @OcaDevice
  func testARefusedCommandIsTheDevicesFailure() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    application.startRefusal = .invalidRequest
    let started = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "transport_file": Self.file, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(started.status, .internalServerError)
    XCTAssertEqual(started.json?["code"], 500)

    application.startRefusal = nil
    try await patchOK(stack, path, ["master_enable": true, "transport_file": Self.file])
    application.stopRefusal = .deviceError
    let stopped = try await patch(stack, path, ["master_enable": false])
    XCTAssertEqual(stopped, .internalServerError)
    XCTAssertEqual(application.endpointStatuses[1]?.state, .running, "a refused Stop changes nothing")
  }

  /// A device that refuses ConnectAndStart or Stop NotImplemented fails the activation like
  /// any other refusal (500), and is put back as it was.
  @OcaDevice
  func testNotImplementedFailsTheActivation() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    application.startRefusal = .notImplemented
    let started = try await patch(stack, path, ["master_enable": true, "transport_file": Self.file])
    XCTAssertEqual(started, .internalServerError)
    XCTAssertEqual(application.configured.map(\.sdp), [Self.multicast, ""])
    XCTAssertEqual(application.endpointStatuses[1]?.state, .notReady)

    application.startRefusal = nil
    try await patchOK(stack, path, ["master_enable": true, "transport_file": Self.file])
    application.stopRefusal = .notImplemented
    let stopped = try await patch(stack, path, ["master_enable": false])
    XCTAssertEqual(stopped, .internalServerError)
    XCTAssertEqual(application.configured.last?.sdp, Self.multicast, "no empty description in its place")
    XCTAssertEqual(application.endpointStatuses[1]?.state, .running)
  }

  /// A scheduled activation configures and starts the receiver when it fires, not before.
  @OcaDevice
  func testAScheduledActivationConfiguresAndStartsWhenItFires() async throws {
    let application = try await makeApplication()
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    let result = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "transport_file": Self.file,
      "activation": ["mode": "activate_scheduled_relative", "requested_time": "0:200000000"],
    ])
    XCTAssertEqual(result.status, .accepted)
    XCTAssertTrue(application.configured.isEmpty)
    XCTAssertTrue(application.commands.isEmpty)
    try await until("the activation fires") { application.endpointStatuses[1]?.state == .running }
    XCTAssertEqual(application.configured.map(\.sdp), [Self.multicast])
    XCTAssertEqual(application.commands.map(\.command), [.connectAndStart])
  }

  /// A device that starts what it is configured with, and can be stopped, is stopped when it
  /// is configured for a disabled receiver.
  @OcaDevice
  func testADeviceThatStartsOnConfigureIsStoppedWhenDisabled() async throws {
    let application = try await makeApplication()
    application.startsOnConfigure = true
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 1))"
    try await patchOK(stack, path, ["master_enable": false, "transport_file": Self.file])
    XCTAssertEqual(application.commands.map(\.command), [.stop])
    XCTAssertEqual(application.endpointStatuses[1]?.state, .ready)
  }

  /// Disabling a receiver of an application that describes its streams itself stops it,
  /// keeping what it was configured with.
  @OcaDevice
  func testDisablingAReceiverDescribedBySDPStopsIt() async throws {
    _ = try await TestDevice.networkManager()
    let application = try await TestDanteAes67Application(
      role: TestDevice.role("DanteAes67"), deviceDelegate: OcaDevice.shared
    )
    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 2, direction: .input, currentStreamMode: Self.mode))
    let stack = try await ConnectionStack([application])
    let path = "receivers/\(await stack.id(application, 2))"
    try await patchOK(stack, path, ["master_enable": true, "transport_file": Self.file])
    XCTAssertEqual(application.active[2], Self.multicast)
    try await patchOK(stack, path, ["master_enable": false])
    XCTAssertNil(application.active[2])
    XCTAssertEqual(application.configuredSDPs[2], Self.multicast)
    let active = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
  }
}
