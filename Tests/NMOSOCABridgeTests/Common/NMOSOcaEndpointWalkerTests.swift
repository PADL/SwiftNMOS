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

/// The one device a process can have, with a network manager, shared by the tests.
@OcaDevice
enum TestDevice {
  private static var manager: SwiftOCADevice.OcaNetworkManager?

  static func networkManager() async throws -> SwiftOCADevice.OcaNetworkManager {
    if let manager { return manager }
    try await OcaDevice.shared.initializeDefaultObjects()
    let manager = try await SwiftOCADevice.OcaNetworkManager(deviceDelegate: OcaDevice.shared)
    self.manager = manager
    return manager
  }

  static func makeApplication(_ role: String) async throws -> SwiftOCADevice.OcaMediaTransportApplication {
    try await SwiftOCADevice.OcaMediaTransportApplication(
      role: "\(role)-\(UUID().uuidString)", deviceDelegate: OcaDevice.shared
    )
  }
}

/// Counts what a walker reports, so a test can wait for a report without hanging if
/// none comes.
private final class ChangeCounter: Sendable {
  private final class Count: Sendable {
    let value = Mutex(0)
  }

  private let count = Count()
  private let task: Task<Void, Never>

  init(_ changes: AsyncStream<Void>) {
    task = Task { [count] in
      for await _ in changes { count.value.withLock { $0 += 1 } }
    }
  }

  deinit { task.cancel() }

  /// Waits until reports stop arriving, then returns how many there have been.
  func settle() async throws -> Int {
    var previous = -1
    while true {
      let current = count.value.withLock { $0 }
      if current == previous { return current }
      previous = current
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  func hasReported(since baseline: Int) async throws -> Bool {
    for _ in 0..<200 {
      if count.value.withLock({ $0 }) > baseline { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

final class NMOSOcaEndpointWalkerTests: XCTestCase {
  @OcaDevice
  func testFindsEndpointsOfEveryApplication() async throws {
    let manager = try await TestDevice.networkManager()
    let walker = NMOSOcaEndpointWalker()
    manager.networkApplications = []
    let none = await walker.endpoints
    XCTAssertTrue(none.isEmpty)

    let aes67 = try await TestDevice.makeApplication("AES67")
    aes67.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input, userLabel: "Rx 1"))
    aes67.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1001, direction: .output, userLabel: "Tx 1"))
    let dante = try await TestDevice.makeApplication("Dante")
    dante.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input))
    manager.networkApplications = [aes67, dante]

    let endpoints = await walker.endpoints
    XCTAssertEqual(endpoints.count, 3)
    XCTAssertEqual(endpoints.filter(\.isSender).map(\.endpoint.userLabel), ["Tx 1"])
    XCTAssertEqual(endpoints.first { $0.isSender }?.kind, .sender)

    // the same endpoint number in two applications is two different receivers
    let ids = NMOSOcaResourceIDs(seed: "seed")
    let receivers = endpoints.filter { !$0.isSender }.map { $0.id(.receiver, in: ids) }
    XCTAssertEqual(Set(receivers).count, 2)
  }

  @OcaDevice
  func testReportsChangesToEndpoints() async throws {
    let manager = try await TestDevice.networkManager()
    let application = try await TestDevice.makeApplication("AES67")
    manager.networkApplications = [application]
    let walker = NMOSOcaEndpointWalker()

    let changes = ChangeCounter(walker.changes())
    // every property reports its current value first
    let initial = try await changes.settle()
    XCTAssertGreaterThan(initial, 0)

    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input))
    let reported = try await changes.hasReported(since: initial)
    XCTAssertTrue(reported)
    let endpoints = await walker.endpoints
    XCTAssertEqual(endpoints.map(\.endpoint.idInternal), [1])

    var labelled = try application.endpoint(1)
    labelled.userLabel = "Rx 1"
    try application.update(endpoint: labelled)
    let settled = try await changes.settle()
    XCTAssertGreaterThan(settled, initial + 1)
  }

  @OcaDevice
  func testObservesApplicationsAddedLater() async throws {
    let manager = try await TestDevice.networkManager()
    manager.networkApplications = []
    let walker = NMOSOcaEndpointWalker()
    let changes = ChangeCounter(walker.changes())
    let initial = try await changes.settle()

    // as an operation mode change does: a new application appears
    let application = try await TestDevice.makeApplication("Dante")
    manager.networkApplications = [application]
    let appeared = try await changes.hasReported(since: initial)
    XCTAssertTrue(appeared)
    let afterAppearing = try await changes.settle()

    // and its endpoints are then observed too
    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 7, direction: .output))
    let observed = try await changes.hasReported(since: afterAppearing)
    XCTAssertTrue(observed)
    let endpoints = await walker.endpoints
    XCTAssertEqual(endpoints.map(\.endpoint.idInternal), [7])
  }
}
