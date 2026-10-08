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

/// The RTP adaptation, counting how often it is asked whether an endpoint is its own:
/// on a real device that question can cost a request to the hardware.
@OcaDevice
private final class CountingAdaptation: NMOSOcaConnecting {
  private let rtp = NMOSOcaRTPAdaptation()
  private(set) var claimsAsked = 0
  /// How often what it reads is asked, which whoever observes the applications does.
  private(set) var readsAsked = 0

  nonisolated init() {}

  func claims(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    claimsAsked += 1
    return await rtp.claims(endpoint)
  }

  var claimProperties: NMOSOcaObservedProperties {
    readsAsked += 1
    return rtp.claimProperties
  }
  var connectionProperties: NMOSOcaObservedProperties { rtp.connectionProperties }

  func transportType(of endpoint: NMOSOcaEndpoint) async -> String { await rtp.transportType(of: endpoint) }

  func constraints(of endpoint: NMOSOcaEndpoint) async throws -> [[String: NMOSConstraint]] {
    try await rtp.constraints(of: endpoint)
  }

  func active(of endpoint: NMOSOcaEndpoint) async throws -> NMOSConnectionState {
    try await rtp.active(of: endpoint)
  }

  func transportFile(of endpoint: NMOSOcaEndpoint) async throws -> NMOSTransportFile? {
    try await rtp.transportFile(of: endpoint)
  }

  func transportParameters(
    from file: NMOSTransportFile,
    for endpoint: NMOSOcaEndpoint
  ) async throws -> [NMOSTransportParameters]? {
    try await rtp.transportParameters(from: file, for: endpoint)
  }

  func activate(_ endpoint: NMOSOcaEndpoint, staged: NMOSConnectionState) async throws {
    try await rtp.activate(endpoint, staged: staged)
  }
}

final class ConnectionProviderClaimTests: XCTestCase {
  private static let stream = """
  v=0\r\no=- 1 1 IN IP4 192.168.1.1\r\ns=Stage\r\nt=0 0\r\nm=audio 5004 RTP/AVP 97\r\n\
  c=IN IP4 239.0.0.1/32\r\na=rtpmap:97 L24/48000/2\r\na=sendonly\r\n
  """
  private static let endpoints = 24

  @OcaDevice
  func testEndpointsAreClaimedOnceUntilTheyChange() async throws {
    _ = try await TestDevice.networkManager()
    let application = try await TestAes67Application(role: TestDevice.role("Aes67"), deviceDelegate: OcaDevice.shared)
    application.networkInterfaceAssignments = try await [TestDevice.interfaceAssignment(address: "192.168.1.20")]
    for id in 1...OcaMediaStreamEndpointID(Self.endpoints) {
      application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: id, direction: .input))
    }
    let counting = CountingAdaptation()
    let stack = try await ConnectionStack([application], adaptations: NMOSOcaAdaptations([counting]))

    // observing the applications starts with a report of everything they hold, so the
    // claims are decided more than once while that goes on; wait until it has
    _ = try await stack.send(.GET, "receivers")
    try await Task.sleep(for: .milliseconds(300))
    let listed = try await stack.send(.GET, "receivers")
    XCTAssertEqual(listed.json?.arrayValue?.count, Self.endpoints)
    let settled = counting.claimsAsked

    // nothing has changed, so listing again asks nothing, where it used to ask about
    // every endpoint once for each endpoint; nor does reading an endpoint
    let again = try await stack.send(.GET, "receivers")
    XCTAssertEqual(again.json, listed.json)
    let path = "receivers/\(stack.id(application, 7))"
    for resource in ["constraints", "staged", "active", "transporttype"] {
      let result = try await stack.send(.GET, "\(path)/\(resource)")
      XCTAssertEqual(result.status, .ok, resource)
    }
    XCTAssertEqual(counting.claimsAsked, settled)

    // a change to the application has its endpoints claimed afresh: once for each time
    // it changed, however many requests there are meanwhile
    let patched = try await stack.send(.PATCH, "\(path)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_file": ["data": .string(Self.stream), "type": "application/sdp"],
    ])
    XCTAssertEqual(patched.status, .ok)
    XCTAssertEqual(application.configured.first?.id, 7)
    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 100, direction: .input))
    _ = try await stack.wait(for: "receivers") { $0.arrayValue?.count == Self.endpoints + 1 }
    try await Task.sleep(for: .milliseconds(300))
    let added = try await stack.send(.GET, "receivers/\(stack.id(application, 100))/active")
    XCTAssertEqual(added.status, .ok)
    let changed = counting.claimsAsked
    XCTAssertGreaterThan(changed, settled)
    XCTAssertLessThan(changed - settled, 8 * (Self.endpoints + 1))
    for _ in 0..<5 { _ = try await stack.send(.GET, "receivers") }
    XCTAssertEqual(counting.claimsAsked, changed)

    // an endpoint that has gone is not found, whatever was decided about it before
    application.remove(endpointID: 7)
    let gone = try await stack.wait(for: "receivers") { $0.arrayValue?.count == Self.endpoints }
    XCTAssertNotNil(gone)
    let removed = try await stack.send(.GET, "\(path)/active")
    XCTAssertEqual(removed.status, .notFound)
  }

  @OcaDevice
  func testAChangeStreamThatEndsStopsObservingTheApplications() async throws {
    let manager = try await TestDevice.networkManager()
    manager.networkApplications = try await [TestDevice.makeApplication("Observed")]
    var counting: CountingAdaptation? = CountingAdaptation()
    weak let adaptation = counting
    var provider: NMOSOcaConnectionProvider? = try NMOSOcaConnectionProvider(
      adaptations: NMOSOcaAdaptations([XCTUnwrap(counting)])
    ) { ConnectionStack.ids }
    counting = nil
    // reading the changes observes the applications, with the adaptations' reads
    let changes = try XCTUnwrap(provider).connectionChanges()
    let reader = Task { for await _ in changes {} }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertGreaterThan(adaptation?.readsAsked ?? 0, 0)

    // whatever observes them holds the adaptations, so they go once nothing does
    reader.cancel()
    provider = nil
    for _ in 0..<100 where adaptation != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(adaptation)
  }
}
