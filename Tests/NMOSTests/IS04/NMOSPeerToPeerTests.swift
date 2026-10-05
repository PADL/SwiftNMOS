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

/// Peer-to-peer operation: the Node API advertisement and its `ver_` records.
final class NMOSPeerToPeerTests: XCTestCase {
  private let resources = FixtureResources()
  private let discovery = FixtureServiceDiscovery()
  private var store: NMOSResourceStore!
  private var running: Task<Void, any Error>?

  override func setUp() async throws {
    store = NMOSResourceStore()
  }

  override func tearDown() async throws {
    await stop()
  }

  private func start(
    httpClient: (any NMOSHTTPClient)? = nil,
    peerToPeer: Bool = true,
    discoveryTimeout: Duration = .milliseconds(30)
  ) {
    let node = NMOSNode(
      configuration: .init(
        peerToPeer: peerToPeer, heartbeatInterval: .milliseconds(40), registryDiscoveryTimeout: discoveryTimeout
      ),
      store: store, discovery: discovery, httpClient: httpClient
    )
    running = Task { try await node.run() }
  }

  private func stop() async {
    running?.cancel()
    _ = await running?.result
    running = nil
  }

  private var live: FixtureServiceDiscovery.Registration? {
    discovery.registrations.last { !$0.isWithdrawn }
  }

  func testAdvertisesTheNodeAPIWithItsVersionRecords() async throws {
    await store.upsert(.node(resources.nodeResource))
    start()
    await eventually("the Node API is advertised") { live != nil }
    let advertisement = try XCTUnwrap(live)
    XCTAssertEqual(advertisement.advertisement.type, "_nmos-node._tcp")
    // the service is named for the node, as the OCA services are named for the device
    XCTAssertEqual(advertisement.advertisement.name, "node")
    XCTAssertEqual(advertisement.advertisement.port, 8080)
    XCTAssertEqual(advertisement.txt["api_proto"], "http")
    XCTAssertEqual(advertisement.txt["api_ver"], "v1.3")
    XCTAssertEqual(advertisement.txt["api_auth"], "false")
    XCTAssertEqual(
      Set(advertisement.txt.keys.filter { $0.hasPrefix("ver_") }),
      ["ver_slf", "ver_src", "ver_flw", "ver_dvc", "ver_snd", "ver_rcv"]
    )
  }

  func testACounterMovesWithItsCollectionAlone() async throws {
    await store.upsert(.node(resources.nodeResource))
    start()
    await eventually("the Node API is advertised") { live != nil }
    let before = try XCTUnwrap(live?.txt)

    await store.upsert(.sender(resources.senderResource))
    await eventually("ver_snd moves") { live?.txt["ver_snd"] != before["ver_snd"] }
    let after = try XCTUnwrap(live?.txt)
    XCTAssertEqual(after["ver_snd"], "1")
    XCTAssertEqual(after.filter { $0.key != "ver_snd" }, before.filter { $0.key != "ver_snd" })
    // the record was updated in place, not advertised afresh
    XCTAssertEqual(discovery.registrations.count, 1)

    await store.remove(.sender, id: resources.sender)
    await eventually("ver_snd moves again") { live?.txt["ver_snd"] == "2" }
  }

  func testARenamedNodeIsAdvertisedAfreshWithItsCountersCarriedOver() async throws {
    await store.upsert(.node(resources.nodeResource))
    await store.upsert(.sender(resources.senderResource))
    start()
    await eventually("the counters settle") { live?.txt["ver_snd"] != nil }
    await store.touch(.sender, id: resources.sender)
    await eventually("ver_snd moves") { live?.txt["ver_snd"] == "1" }
    let first = try XCTUnwrap(live)
    let before = first.txt

    var renamed = resources.nodeResource
    renamed.label = "Studio B"
    await store.upsert(.node(renamed))
    await eventually("the node is advertised under its new name") { live?.advertisement.name == "Studio B" }
    let second = try XCTUnwrap(live)

    // a service cannot be renamed in place: the old one goes and a new one comes
    XCTAssertTrue(first.isWithdrawn)
    XCTAssertEqual(discovery.registrations.count, 2)
    XCTAssertEqual(second.advertisement.port, first.advertisement.port)
    // the rename is a change to the node, and nothing else's counter is lost or moved
    XCTAssertEqual(second.txt["ver_slf"], String(Int(before["ver_slf"]!)! + 1))
    XCTAssertEqual(second.txt.filter { $0.key != "ver_slf" }, before.filter { $0.key != "ver_slf" })
  }

  func testAChangeOtherThanTheLabelUpdatesTheRecordInPlace() async throws {
    await store.upsert(.node(resources.nodeResource))
    start()
    await eventually("the Node API is advertised") { live != nil }
    let advertisement = try XCTUnwrap(live)
    let before = advertisement.txt

    var described = resources.nodeResource
    described.description = "now with a description"
    described.clocks = [.internal(name: "clk0")]
    await store.upsert(.node(described))
    await eventually("ver_slf moves") { advertisement.txt["ver_slf"] != before["ver_slf"] }
    await store.upsert(.sender(resources.senderResource))
    await eventually("ver_snd moves") { advertisement.txt["ver_snd"] != before["ver_snd"] }

    XCTAssertFalse(advertisement.isWithdrawn)
    XCTAssertEqual(discovery.registrations.count, 1)
    XCTAssertEqual(advertisement.advertisement.name, "node")
  }

  func testTheServiceNameFitsADNSLabel() async throws {
    // 20 three-byte characters fit in 63 bytes; a twenty-second would not
    var node = resources.nodeResource
    node.label = String(repeating: "音", count: 30)
    await store.upsert(.node(node))
    start()
    await eventually("the Node API is advertised") { live != nil }
    let name = try XCTUnwrap(live?.advertisement.name)
    XCTAssertEqual(name, String(repeating: "音", count: 21))
    XCTAssertEqual(name.utf8.count, 63)

    // an unlabelled node leaves its name to the responder
    node.label = ""
    await store.upsert(.node(node))
    await eventually("the node is advertised without a name") { live != nil && live?.advertisement.name == nil }
  }

  func testACounterWrapsAfter255() async throws {
    await store.upsert(.node(resources.nodeResource))
    await store.upsert(.sender(resources.senderResource))
    start()
    await eventually("the Node API is advertised") { live != nil }
    await eventually("the counters settle") { live?.txt["ver_snd"] == "0" }
    for _ in 0..<255 {
      await store.touch(.sender, id: resources.sender)
    }
    await eventually("ver_snd reaches 255") { live?.txt["ver_snd"] == "255" }
    await store.touch(.sender, id: resources.sender)
    await eventually("ver_snd wraps to 0") { live?.txt["ver_snd"] == "0" }
  }

  func testWithdrawsTheAdvertisementWhileARegistryIsInUse() async throws {
    let registry = FixtureRegistry()
    await store.upsert(.node(resources.nodeResource))
    start(httpClient: registry.client)
    await eventually("the Node API is advertised") { live != nil }

    let service = NMOSDiscoveredService(
      name: "registry", host: "registry", port: 8010,
      txt: ["api_ver": "v1.3", "api_proto": "http", "api_auth": "false", "pri": "0"]
    )
    discovery.publish([service], type: NMOSServiceType.registration)
    await eventually("the node is registered") { registry.holds("node", resources.node) }
    await eventually("the advertisement is withdrawn") { live == nil }

    // the registry goes away for good: back to peer-to-peer
    registry.override { _ in throw NMOSHTTPClientError.timedOut }
    discovery.publish([], type: NMOSServiceType.registration)
    await eventually("the Node API is advertised again") { live != nil }
  }

  func testWaitsForBrowsingBeforeConcludingThereIsNoRegistry() async throws {
    // browsing that finds nothing says nothing, so only time can tell
    let registry = FixtureRegistry()
    await store.upsert(.node(resources.nodeResource))
    start(httpClient: registry.client, discoveryTimeout: .milliseconds(300))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(discovery.registrations.isEmpty)
    await eventually("the Node API is advertised") { live != nil }
    XCTAssertEqual(registry.calls, [])
  }

  func testARegistryFoundWhileWaitingIsUsedWithoutAdvertising() async throws {
    let registry = FixtureRegistry()
    await store.upsert(.node(resources.nodeResource))
    start(httpClient: registry.client, discoveryTimeout: .milliseconds(300))
    try await Task.sleep(for: .milliseconds(50))
    let service = NMOSDiscoveredService(
      name: "registry", host: "registry", port: 8010,
      txt: ["api_ver": "v1.3", "api_proto": "http", "api_auth": "false", "pri": "0"]
    )
    discovery.publish([service], type: NMOSServiceType.registration)
    await eventually("the node is registered") { registry.holds("node", resources.node) }
    try await Task.sleep(for: .milliseconds(350))
    // the `ver_` records were never published, so there are none to withdraw
    XCTAssertTrue(discovery.registrations.isEmpty)
  }

  func testOperatesPeerToPeerAtOnceWhereItCannotRegister() async throws {
    // without an HTTP client there is no registry to wait for
    await store.upsert(.node(resources.nodeResource))
    start(discoveryTimeout: .seconds(60))
    await eventually("the Node API is advertised", timeout: .seconds(1)) { live != nil }
  }

  func testDoesNotAdvertiseWhenPeerToPeerIsOff() async throws {
    await store.upsert(.node(resources.nodeResource))
    start(peerToPeer: false)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(discovery.registrations.isEmpty)
  }

  func testWithdrawsTheAdvertisementOnShutdown() async throws {
    await store.upsert(.node(resources.nodeResource))
    start()
    await eventually("the Node API is advertised") { live != nil }
    await stop()
    XCTAssertNil(live)
  }
}
