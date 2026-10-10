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
import Synchronization
import XCTest

/// A device the size of a Monitor Two in Milan mode (a Dante application of 64 channels
/// each way, a Milan one, an interface and a clock) whose transport reports counters
/// and status twice a second, as an AVB entity does, while nothing else changes.
final class NMOSOcaIdleLoadTests: XCTestCase {
  @OcaDevice
  func testCountersAndStatusReportedByATransportDoNotHaveTheDeviceDescribedAgain() async throws {
    let manager = try await TestDevice.networkManager()
    let device = OcaDevice.shared
    func role(_ name: String) -> String { "\(name)-\(UUID().uuidString)" }

    let clock = try await SwiftOCADevice.OcaMediaClock3(role: role("Clock"), deviceDelegate: device)
    let interface = try await SwiftOCADevice.OcaNetworkInterface(role: role("Interface"), deviceDelegate: device)
    interface.adaptationIdentifier = MilanAdaptation.identifier
    let dante = try await SwiftOCADevice.DanteOcaMediaTransportApplication(role: role("Dante"), deviceDelegate: device)
    for channel in 1...64 {
      dante.insert(
        endpoint: OcaMediaStreamEndpoint(
          idInternal: OcaMediaStreamEndpointID(1000 + channel), idExternal: OcaBlob(String(format: "%02d", channel).utf8),
          direction: .output, clockONo: clock.objectNumber
        ),
        status: .init(state: .ready)
      )
      dante.insert(
        endpoint: OcaMediaStreamEndpoint(idInternal: OcaMediaStreamEndpointID(channel), direction: .input),
        status: .init(state: .ready)
      )
    }
    let milan = try await TestDevice.makeApplication("Milan")
    milan.adaptationIdentifier = MilanAdaptation.identifier
    for stream in 1...2 {
      milan.insert(
        endpoint: OcaMediaStreamEndpoint(
          idInternal: OcaMediaStreamEndpointID(stream), direction: .input,
          currentStreamMode: OcaMediaStreamMode(
            frameFormat: .aaf, encodingType: "audio/L32", samplingRate: 48000, channelCount: 8, packetTime: 125e-6
          )
        ),
        status: .init(state: .connected)
      )
    }
    manager.networkInterfaces = [interface]
    manager.networkApplications = [dante, milan]

    let described = Mutex(0)
    let store = NMOSResourceStore()
    let read = Mutex(0)
    let bridge = NMOSOcaBridge(store: store) {
      described.withLock { $0 += 1 }
      return NMOSOcaHost(
        seed: "00-22-97-01-02-03", hostname: "monitortwo", endpoints: [.init(host: "10.0.0.5", port: 80)],
        interfaces: [.init(name: "br0", chassisID: nil, portID: "00-22-97-01-02-03")]
      )
    }
    let running = Task { try await bridge.run() }
    defer { running.cancel() }
    // the Connection API reads every connection again at each change it is told of
    let connections = Task {
      for await _ in NMOSOcaEndpointWalker(device: device).changes() { read.withLock { $0 += 1 } }
    }
    defer { connections.cancel() }

    // let it describe the device as it starts, and settle
    try await Task.sleep(for: .milliseconds(500))
    let resources = await store.senders.count + store.receivers.count
    XCTAssertEqual(resources, 130)
    let before = (described: described.withLock { $0 }, read: read.withLock { $0 })

    // an idle entity's reports: counters, and status and availability, which NMOS does
    // not read, whether or not they changed
    for report in 1...10 {
      milan.endpointCounterSets = [1: OcaCounterSet(), 2: OcaCounterSet()]
      milan.endpointStatuses[1] = .init(state: report % 2 == 0 ? .connected : .notReady)
      milan.counterSet = OcaCounterSet()
      interface.counterSet = OcaCounterSet()
      interface.status = interface.status
      clock.availability = .available
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(described.withLock { $0 }, before.described, "the device was described again")
    XCTAssertEqual(read.withLock { $0 }, before.read, "a change was reported to the Connection API")

    // a change NMOS is told of is still observed
    milan.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 3, direction: .input), status: .init(state: .ready))
    for _ in 0..<300 where await store.receivers.count != 67 {
      try await Task.sleep(for: .milliseconds(10))
    }
    let receivers = await store.receivers.count
    XCTAssertEqual(receivers, 67)
    XCTAssertGreaterThan(read.withLock { $0 }, before.read)
  }
}
