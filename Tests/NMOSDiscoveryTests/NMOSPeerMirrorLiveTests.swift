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
import NMOSClient
import NMOSDiscovery
import Synchronization
import XCTest

/// Collects what a mirror delivers, so a test can look without ending the stream.
private final class Snapshots: Sendable {
  private final class Box: Sendable {
    let value = Mutex(NMOSRegistrySnapshot?.none)
  }

  private let box = Box()
  private let task: Task<Void, Never>

  init(_ mirror: NMOSPeerMirror) {
    let snapshots = mirror.snapshots()
    task = Task { [box] in
      for await snapshot in snapshots {
        box.value.withLock { $0 = snapshot }
      }
    }
  }

  deinit { task.cancel() }

  /// The snapshot once it satisfies `predicate`, nil if it doesn't in time.
  func wait(until predicate: (NMOSRegistrySnapshot) -> Bool) async -> NMOSRegistrySnapshot? {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if let snapshot = box.value.withLock({ $0 }), predicate(snapshot) { return snapshot }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }
}

/// A real node, its real Node API and whichever DNS-SD responder the host has, skipped where
/// it has none. Everything here is advertised and browsed for as the tests' own service type,
/// so no NMOS controller on the network mistakes the node for one to control.
final class NMOSPeerMirrorLiveTests: XCTestCase {
  private struct TestDiscovery: NMOSServiceDiscovery {
    static let type = "_nmos-test._tcp"

    let discovery = NMOSOcaServiceDiscovery()

    func advertise(_ advertisement: NMOSServiceAdvertisement) async throws -> any NMOSServiceRegistration {
      try await discovery.advertise(NMOSServiceAdvertisement(
        type: Self.type, name: advertisement.name, port: advertisement.port, txt: advertisement.txt
      ))
    }

    func browse(type: String) -> AsyncStream<[NMOSDiscoveredService]> {
      discovery.browse(type: Self.type)
    }
  }

  private static func decode<Resource: Decodable>(_ json: String) throws -> Resource {
    try JSONDecoder().decode(Resource.self, from: Data(json.utf8))
  }

  private let nodeID = UUID().uuidString.lowercased()
  private let deviceID = UUID().uuidString.lowercased()

  private func nodeResource(label: String, port: UInt16) throws -> NMOSNodeResource {
    try Self.decode("""
    {"api":{"endpoints":[{"host":"127.0.0.1","port":\(port),"protocol":"http"}],"versions":["v1.3"]},
     "caps":{},"clocks":[],"description":"","hostname":"test","href":"http://127.0.0.1:\(port)/",
     "id":"\(nodeID)","interfaces":[],"label":"\(label)","services":[],"tags":{},
     "version":"1793438317:873445749"}
    """)
  }

  private func device() throws -> NMOSDeviceResource {
    try Self.decode("""
    {"controls":[],"description":"","id":"\(deviceID)","label":"test","node_id":"\(nodeID)",
     "receivers":[],"senders":[],"tags":{},"type":"urn:x-nmos:device:generic",
     "version":"1793438317:739358425"}
    """)
  }

  private func sender(_ label: String) throws -> NMOSSenderResource {
    try Self.decode("""
    {"description":"","device_id":"\(deviceID)","flow_id":"\(UUID().uuidString.lowercased())",
     "id":"\(UUID().uuidString.lowercased())","interface_bindings":[],"label":"\(label)",
     "manifest_href":null,"subscription":{"active":false,"receiver_id":null},"tags":{},
     "transport":"urn:x-nmos:transport:rtp.mcast","version":"1793438317:739514827"}
    """)
  }

  func testAPeerIsFollowedByWhatItAdvertises() async throws {
    let label = "NMOS test \(UInt32.random(in: 0...UInt32.max))"
    let discovery = TestDiscovery()
    let store = NMOSResourceStore()
    let server = try HTTPServer(address: .inet(ip4: "0.0.0.0", port: 0))
    let node = NMOSNode(store: store, discovery: discovery)
    await node.attach(to: server)
    let serving = Task { try await server.run() }
    defer { serving.cancel() }
    try await server.waitUntilListening()
    guard case let .ip4(_, port) = await server.listeningAddress else {
      return XCTFail("the server is not listening on IPv4")
    }

    let description = try nodeResource(label: label, port: port)
    await store.upsert(.node(description))
    try await store.upsert(.device(device()))
    let first = try sender("first")
    await store.upsert(.sender(first))
    let running = Task { try await node.run() }
    defer { running.cancel() }

    let snapshots = Snapshots(NMOSPeerMirror(discovery: discovery))
    let id = description.id

    guard let found = await snapshots.wait(until: { $0.nodes[id] != nil }) else {
      throw XCTSkip("the DNS-SD responder did not report the advertised service")
    }
    XCTAssertEqual(found.nodes[id]?.label, label)
    XCTAssertEqual(found.senders[first.id]?.label, "first")

    // only the TXT record changes, and only that says so
    let second = try sender("second")
    await store.upsert(.sender(second))
    let added = await snapshots.wait { $0.senders[second.id] != nil }
    XCTAssertEqual(added?.senders[first.id]?.label, "first")

    await store.remove(.sender, id: first.id)
    let removed = await snapshots.wait { $0.senders[first.id] == nil }
    XCTAssertEqual(removed?.senders[second.id]?.label, "second")

    running.cancel()
    _ = await running.result
    let left = await snapshots.wait { $0.nodes[id] == nil }
    XCTAssertNotNil(left)
  }
}
