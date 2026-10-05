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
import XCTest

final class NMOSOcaSearchDomainsTests: XCTestCase {
  private func service(_ name: String, host: String) -> NMOSDiscoveredService {
    NMOSDiscoveredService(name: name, host: host, port: 8010, txt: ["pri": "100"])
  }

  /// IS-04: a node browses its search domain by unicast DNS, and uses mDNS only where
  /// that finds nothing.
  func testWhatUnicastDNSFindsIsUsedInPreferenceToWhatMDNSFinds() async {
    let (stream, continuation) = AsyncStream<[NMOSDiscoveredService]>.makeStream()
    let found = NMOSOcaDiscoveredServices(continuation: continuation)
    var reports = stream.makeAsyncIterator()
    let multicast = service("Lab registry", host: "169.254.1.2")
    let site = service("Site registry", host: "10.0.0.5")
    let backup = service("Backup registry", host: "10.0.0.6")

    // nothing is reported while nothing has been found anywhere
    await found.found([], in: "example.com")
    await found.found([multicast], in: nil)
    var report = await reports.next()
    XCTAssertEqual(report, [multicast])

    await found.found([site], in: "example.com")
    report = await reports.next()
    XCTAssertEqual(report, [site])

    // a second search domain adds to the first; the same registry in both is one
    await found.found([backup, site], in: "plant.example.com")
    report = await reports.next()
    XCTAssertEqual(report, [site, backup])

    // mDNS finding more changes nothing while unicast DNS has an answer
    await found.found([multicast, service("Another", host: "169.254.1.3")], in: nil)
    await found.found([], in: "plant.example.com")
    report = await reports.next()
    XCTAssertEqual(report, [site])

    // with nothing left in the search domains, mDNS's answer is used again
    await found.found([], in: "example.com")
    report = await reports.next()
    XCTAssertEqual(report?.map(\.name), ["Lab registry", "Another"])

    await found.found([], in: nil)
    report = await reports.next()
    XCTAssertEqual(report, [])
  }
}
