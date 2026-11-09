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
import XCTest

final class NMOSOcaResourceIDsTests: XCTestCase {
  func testTheSameSeedGivesTheSameIDs() {
    let first = NMOSOcaResourceIDs(seed: "00:22:97:01:02:03")
    let second = NMOSOcaResourceIDs(seed: "00:22:97:01:02:03")
    XCTAssertEqual(first, second)
    XCTAssertEqual(
      first.id(.sender, application: 0x1000F, endpoint: 1001),
      second.id(.sender, application: 0x1000F, endpoint: 1001)
    )
  }

  func testIDsAreUniqueToTheDevice() {
    let first = NMOSOcaResourceIDs(seed: "00:22:97:01:02:03")
    let second = NMOSOcaResourceIDs(seed: "00:22:97:01:02:04")
    XCTAssertNotEqual(first.node, second.node)
    XCTAssertNotEqual(first.device, second.device)
    XCTAssertNotEqual(
      first.id(.receiver, application: 1, endpoint: 1),
      second.id(.receiver, application: 1, endpoint: 1)
    )
  }

  func testEveryResourceOfADeviceHasItsOwnID() {
    let ids = NMOSOcaResourceIDs(seed: "seed")
    var seen: Set<NMOSID> = [ids.node, ids.device]
    for kind in [NMOSResourceKind.source, .flow, .sender, .receiver] {
      for application: OcaONo in [0x1000F, 0x2000F] {
        for endpoint: UInt32 in [1, 2, 1001] {
          let id = ids.id(kind, application: application, endpoint: endpoint)
          XCTAssertTrue(seen.insert(id).inserted, "\(kind) \(application) \(endpoint)")
        }
      }
    }
  }

  func testIDsAreVersion5() {
    let ids = NMOSOcaResourceIDs(seed: "seed")
    for id in [ids.node, ids.device, ids.id(.flow, application: 1, endpoint: 1)] {
      let fields = id.description.split(separator: "-")
      XCTAssertEqual(fields[2].first, "5")
      XCTAssertTrue("89ab".contains(fields[3].first!))
    }
  }

  func testEachResourceOfANativeEndpointHasItsOwnID() {
    var seen = Set<NMOSID>()
    for kind in [NMOSResourceKind.source, .flow, .sender, .receiver] {
      for native in ["ieee1722:001122fffe334455:0", "ieee1722:001122fffe334455:1"] {
        let id = NMOSOcaResourceIDs.id(kind, native: native)
        XCTAssertTrue(seen.insert(id).inserted, "\(kind) \(native)")
        XCTAssertEqual(id.description.split(separator: "-")[2].first, "5")
      }
    }
  }

  /// A Dante name is unique only within its network, so two devices with the same
  /// device name (two bridges left with the default one) give different IDs, and a
  /// name never gives the ID an IEEE 1722 name or a seeded endpoint does.
  func testADanteNameIsQualifiedByTheDevice() {
    let first = NMOSOcaResourceIDs(seed: "00-22-97-01-02-03")
    let second = NMOSOcaResourceIDs(seed: "00-22-97-0A-0B-0C")
    for kind in [NMOSResourceKind.source, .flow, .sender, .receiver] {
      let native = "dante:Left@RouterOne"
      XCTAssertEqual(first.id(kind, deviceNative: native), first.id(kind, deviceNative: native))
      XCTAssertNotEqual(first.id(kind, deviceNative: native), second.id(kind, deviceNative: native))
      XCTAssertNotEqual(first.id(kind, deviceNative: native), NMOSOcaResourceIDs.id(kind, native: native))
      XCTAssertNotEqual(first.id(kind, deviceNative: native), first.id(kind, application: 1, endpoint: 1))
    }
    XCTAssertNotEqual(first.id(.sender, deviceNative: "dante:Left@RouterOne"), first.id(.receiver, deviceNative: "dante:Left@RouterOne"))
  }
}
