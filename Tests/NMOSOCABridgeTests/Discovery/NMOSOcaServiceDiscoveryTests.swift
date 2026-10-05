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
import XCTest

/// Runs against whichever DNS-SD responder the host has and is skipped where it has
/// none. The service type is the tests' own, so no NMOS controller mistakes it for a node.
final class NMOSOcaServiceDiscoveryTests: XCTestCase {
  private static let type = "_nmos-test._tcp"

  private let discovery = NMOSOcaServiceDiscovery()

  private func advertisement(_ name: String, txt: [String: String]) -> NMOSServiceAdvertisement {
    NMOSServiceAdvertisement(type: Self.type, name: name, port: 49153, txt: txt)
  }

  private func uniqueName() -> String {
    "NMOS test \(UInt32.random(in: 0...UInt32.max))"
  }

  /// The first set of services browsing reports that satisfies `predicate`, nil if none
  /// does in time.
  private func browse(
    within timeout: Duration = .seconds(8),
    until predicate: @escaping @Sendable ([NMOSDiscoveredService]) -> Bool
  ) async -> [NMOSDiscoveredService]? {
    let found = discovery.browse(type: Self.type)
    return await withTaskGroup(of: [NMOSDiscoveredService]?.self) { group in
      group.addTask {
        for await services in found where predicate(services) { return services }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  private func advertise(_ advertisement: NMOSServiceAdvertisement) async throws -> any NMOSServiceRegistration {
    do {
      return try await discovery.advertise(advertisement)
    } catch {
      throw XCTSkip("no DNS-SD responder to advertise with: \(error)")
    }
  }

  func testAnAdvertisedServiceIsFoundResolved() async throws {
    let name = uniqueName()
    let txt = ["api_proto": "http", "api_ver": "v1.3", "api_auth": "false", "ver_slf": "0"]
    let registration = try await advertise(advertisement(name, txt: txt))
    defer { Task { await registration.withdraw() } }

    guard let services = await browse(until: { $0.contains { $0.name == name } }) else {
      throw XCTSkip("the DNS-SD responder did not report the advertised service")
    }
    let service = try XCTUnwrap(services.first { $0.name == name })
    XCTAssertEqual(service.port, 49153)
    XCTAssertEqual(service.txt, txt)
    XCTAssertFalse(service.host.isEmpty)
    XCTAssertFalse(service.host.hasSuffix("."))
    await registration.withdraw()
  }

  func testAnUpdateReplacesTheTXTRecordOfTheSameService() async throws {
    let name = uniqueName()
    let registration = try await advertise(advertisement(name, txt: ["ver_slf": "0", "ver_snd": "7"]))
    defer { Task { await registration.withdraw() } }
    guard await browse(until: { $0.contains { $0.name == name } }) != nil else {
      throw XCTSkip("the DNS-SD responder did not report the advertised service")
    }

    try await registration.update(txt: ["ver_slf": "1", "ver_snd": "7"])
    // a new browse resolves afresh; the responder may answer from its cache at first
    var updated: NMOSDiscoveredService?
    for _ in 0..<10 {
      updated = await browse(until: { $0.contains { $0.name == name } })?.first { $0.name == name }
      if updated?.txt["ver_slf"] == "1" { break }
      try await Task.sleep(for: .milliseconds(300))
    }
    XCTAssertEqual(updated?.txt, ["ver_slf": "1", "ver_snd": "7"])
    await registration.withdraw()
  }

  func testAWithdrawnServiceLeavesTheBrowse() async throws {
    let name = uniqueName()
    let registration = try await advertise(advertisement(name, txt: [:]))
    let found = discovery.browse(type: Self.type)
    let observed = Task { () -> [Bool] in
      var sightings = [Bool]()
      for await services in found {
        sightings.append(services.contains { $0.name == name })
        if sightings.contains(true), sightings.last == false { break }
      }
      return sightings
    }
    let deadline = Task {
      try await Task.sleep(for: .seconds(8))
      observed.cancel()
    }
    // withdraw once the browse has had time to find the service
    try await Task.sleep(for: .seconds(2))
    await registration.withdraw()
    let sightings = await observed.value
    deadline.cancel()

    guard sightings.contains(true) else {
      throw XCTSkip("the DNS-SD responder did not report the advertised service")
    }
    XCTAssertEqual(sightings.last, false)

    do {
      try await registration.update(txt: ["ver_slf": "1"])
      XCTFail("a withdrawn service has no TXT record to replace")
    } catch {}
  }
}
