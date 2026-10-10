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
import NMOSOCABridge
import SwiftOCA
import SwiftOCADevice
import Synchronization
import XCTest

private func host(seed: String = "00-22-97-01-02-03") -> NMOSOcaHost {
  NMOSOcaHost(
    seed: seed,
    hostname: "monitortwo",
    endpoints: [.init(host: "10.0.0.5", port: 80), .init(host: "10.0.1.5", port: 80)],
    interfaces: [.init(name: "lan0", chassisID: nil, portID: "00-22-97-01-02-03")]
  )
}

private final class Seed: Sendable {
  let value = Mutex("first")
}

/// A host whose first answer is held back until the test lets it go, and is stale by then.
private final class SlowHost: Sendable {
  let calls = Mutex(0)
  let address = Mutex("10.0.0.5")
  let (gate, open) = AsyncStream<Void>.makeStream()

  func host() async -> NMOSOcaHost {
    let call = calls.withLock { $0 += 1; return $0 }
    let address = address.withLock { $0 }
    if call == 1 { for await _ in gate { break } }
    return NMOSOcaHost(seed: "00-22-97-01-02-03", endpoints: [.init(host: address, port: 80)])
  }
}

final class NMOSOcaNodeDescriptionTests: XCTestCase {
  @OcaDevice
  func testDescribesTheNodeFromTheDeviceManager() async throws {
    _ = try await TestDevice.networkManager()
    let deviceManagerValue = await OcaDevice.shared.deviceManager
    let deviceManager = try XCTUnwrap(deviceManagerValue)
    deviceManager.deviceName = "MonitorTwo-MT0203"
    deviceManager.modelDescription = OcaModelDescription(manufacturer: "Lukktone", name: "Monitor Two", version: "1.0")

    let store = NMOSResourceStore()
    let host = host()
    let bridge = NMOSOcaBridge(store: store) { host }
    await bridge.describe()

    let nodeValue = await store.node
    let node = try XCTUnwrap(nodeValue)
    XCTAssertEqual(node.id, NMOSOcaResourceIDs(seed: host.seed).node)
    XCTAssertEqual(bridge.ids?.node, node.id)
    XCTAssertEqual(node.label, "MonitorTwo-MT0203")
    XCTAssertEqual(node.description, "Lukktone Monitor Two")
    XCTAssertEqual(node.hostname, "monitortwo")
    XCTAssertEqual(node.href, "http://10.0.0.5:80/")
    XCTAssertEqual(node.api.versions, [.v1_3])
    XCTAssertEqual(node.api.endpoints.map(\.host), ["10.0.0.5", "10.0.1.5"])
    XCTAssertEqual(node.interfaces.map(\.name), ["lan0"])

    // describing again without a change leaves the version alone
    await bridge.describe()
    let again = await store.node
    XCTAssertEqual(again?.version, node.version)
  }

  @OcaDevice
  func testObservesTheDeviceName() async throws {
    _ = try await TestDevice.networkManager()
    let deviceManagerValue = await OcaDevice.shared.deviceManager
    let deviceManager = try XCTUnwrap(deviceManagerValue)
    deviceManager.deviceName = "Before"

    let store = NMOSResourceStore()
    let host = host()
    let bridge = NMOSOcaBridge(store: store) { host }
    let running = Task { try await bridge.run() }
    defer { running.cancel() }

    try await waitFor { await store.node?.label == "Before" }
    let beforeValue = await store.node
    let before = try XCTUnwrap(beforeValue)

    deviceManager.deviceName = "After"
    try await waitFor { await store.node?.label == "After" }
    let afterValue = await store.node
    let after = try XCTUnwrap(afterValue)
    XCTAssertEqual(after.id, before.id)
    XCTAssertGreaterThan(after.version, before.version)
  }

  @OcaDevice
  func testADifferentSeedIsADifferentNode() async throws {
    _ = try await TestDevice.networkManager()
    let seed = Seed()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { host(seed: seed.value.withLock { $0 }) }
    await bridge.describe()
    let firstValue = await store.node
    let first = try XCTUnwrap(firstValue)

    seed.value.withLock { $0 = "second" }
    await bridge.describe()
    let nodes = await store.resources(.node)
    XCTAssertEqual(nodes.count, 1)
    XCTAssertNotEqual(nodes.first?.id, first.id)
  }

  @OcaDevice
  func testAnOlderDescriptionIsNeverWrittenLast() async throws {
    _ = try await TestDevice.networkManager()
    let slow = SlowHost()
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) { await slow.host() }
    let first = Task { await bridge.describe() }
    try await waitFor { slow.calls.withLock { $0 } == 1 }

    // the host moves while the first describe is held; a second must not finish before it
    slow.address.withLock { $0 = "10.0.0.6" }
    let second = Task { await bridge.describe() }
    try await Task.sleep(for: .milliseconds(50))
    slow.open.finish()
    await first.value
    await second.value
    let node = await store.node
    XCTAssertEqual(node?.api.endpoints.map(\.host), ["10.0.0.6"])
  }

  @OcaDevice
  func testARunningBridgeDescribesAHostChangeItIsToldOf() async throws {
    _ = try await TestDevice.networkManager()
    let address = Seed()
    address.value.withLock { $0 = "10.0.0.5" }
    let store = NMOSResourceStore()
    let bridge = NMOSOcaBridge(store: store) {
      NMOSOcaHost(seed: "00-22-97-01-02-03", endpoints: [.init(host: address.value.withLock { $0 }, port: 80)])
    }
    let running = Task { try await bridge.run() }
    defer { running.cancel() }
    try await waitFor { await store.node?.api.endpoints.map(\.host) == ["10.0.0.5"] }

    address.value.withLock { $0 = "10.0.0.6" }
    await bridge.describe()
    try await waitFor { await store.node?.api.endpoints.map(\.host) == ["10.0.0.6"] }
  }
}

private func waitFor(
  _ condition: @Sendable () async -> Bool,
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  for _ in 0..<200 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  XCTFail("the condition did not become true", file: file, line: line)
}
