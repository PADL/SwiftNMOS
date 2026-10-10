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
import FlyingSocks
import Foundation
import NMOS
import NMOSOCABridge
import SwiftOCA
import SwiftOCADevice
import XCTest

/// Not a test of its own. It serves an NMOS node over stand-in AES67, Dante and Milan
/// applications, so the AMWA NMOS Testing Tool can be run against the Connection API
/// and the bridge without hardware. Skipped unless NMOS_CONFORMANCE_PORT is set:
///
///   NMOS_CONFORMANCE_PORT=8105 [NMOS_CONFORMANCE_RTP_ONLY=1] swift test --filter ConnectionConformanceHost
///   docker run --rm --network host amwa/nmos-testing python3 nmos-test.py \
///     suite IS-05-01 --host 127.0.0.1 --port 8105 --version v1.1
final class ConnectionConformanceHost: XCTestCase {
  // the connection line is in the media section, where the tool looks for it
  private static let stream = """
  v=0\r\no=- 1311738121 1311738121 IN IP4 192.168.1.20\r\ns=Conformance\r\nt=0 0\r\n\
  m=audio 5004 RTP/AVP 97\r\nc=IN IP4 239.69.0.1/32\r\n\
  a=source-filter: incl IN IP4 239.69.0.1 192.168.1.20\r\na=rtpmap:97 L24/48000/2\r\na=sendonly\r\n\
  a=ptime:1\r\na=ts-refclk:ptp=IEEE1588-2008:39-A7-94-FF-FE-07-CB-D0:0\r\na=mediaclk:direct=0\r\n
  """

  @OcaDevice
  func testServeForTheNMOSTestingTool() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let port = environment["NMOS_CONFORMANCE_PORT"].flatMap(UInt16.init) else {
      throw XCTSkip("set NMOS_CONFORMANCE_PORT to serve a node for the NMOS Testing Tool")
    }
    let seconds = environment["NMOS_CONFORMANCE_SECONDS"].flatMap(Int.init) ?? 300

    let manager = try await TestDevice.networkManager()
    let mode = OcaMediaStreamMode(
      frameFormat: .rtp, encodingType: "audio/L24", samplingRate: 48000, channelCount: 2, packetTime: 1e-3
    )
    let aes67 = try await TestAes67Application(role: TestDevice.role("Aes67"), deviceDelegate: OcaDevice.shared)
    aes67.networkInterfaceAssignments = try await [TestDevice.interfaceAssignment(address: "192.168.1.20")]
    for id: OcaMediaStreamEndpointID in [1, 2] {
      aes67.insert(endpoint: OcaMediaStreamEndpoint(idInternal: id, direction: .input, currentStreamMode: mode))
    }
    aes67.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1001, direction: .output, currentStreamMode: mode))
    try aes67.setActiveSDP(Self.stream, endpoint: 1001)

    let dante = try await TestDanteApplication(role: TestDevice.role("Dante"), deviceDelegate: OcaDevice.shared)
    try dante.addChannel(1, name: "01", direction: .input)
    try dante.addChannel(1001, name: "Left", direction: .output)

    let milan = try await TestDevice.makeApplication("Milan")
    milan.adaptationIdentifier = MilanAdaptation.identifier
    let agent = try await TestMilanSessionAgent(role: TestDevice.role("Sessions"), deviceDelegate: OcaDevice.shared)
    milan.transportSessionControlAgentONos = [agent.objectNumber]
    milan.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input))
    try agent.insert(session: SwiftOCADevice.MilanOcaMediaTransportSessionAgent.makeSession(inputEndpointID: 1))
    try milan.insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: 1001,
      idExternal: MilanMediaStreamEndpointIDExternal(entityID: 0x0011_22FF_FE33_4455, streamIndex: 0).blob,
      direction: .output
    ))
    // the tool takes every transport it does not know to be RTP, so it can be spared the others
    let rtpOnly = environment["NMOS_CONFORMANCE_RTP_ONLY"] != nil
    manager.networkApplications = rtpOnly ? [aes67] : [aes67, dante, milan]

    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) {
      NMOSOcaHost(seed: ConnectionStack.seed, endpoints: [.init(host: "127.0.0.1", port: Int(port))])
    }
    let node = NMOSNode(store: store, connectionProvider: bridge.connectionProvider)
    let server = try HTTPServer(address: .inet(ip4: "0.0.0.0", port: port))
    await node.attach(to: server)
    let serving = Task { try await server.run() }
    let describing = Task { try await bridge.run() }
    let running = Task { try await node.run() }
    try await server.waitUntilListening()
    try await Task.sleep(for: .seconds(seconds))
    running.cancel()
    describing.cancel()
    await server.stop()
    serving.cancel()
  }
}
