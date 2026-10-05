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

final class NMOSTimestampTests: XCTestCase {
  func testParsesAndDescribes() throws {
    let timestamp = try XCTUnwrap(NMOSTimestamp("1441700172:318426300"))
    XCTAssertEqual(timestamp, NMOSTimestamp(seconds: 1_441_700_172, nanoseconds: 318_426_300))
    XCTAssertEqual(timestamp.description, "1441700172:318426300")
    // the separator is a colon: this is not a decimal fraction
    XCTAssertEqual(NMOSTimestamp("1439299836:10")?.nanoseconds, 10)
    XCTAssertNil(NMOSTimestamp("1439299836.10"))
    XCTAssertNil(NMOSTimestamp("1439299836:1000000000"))
    XCTAssertNil(NMOSTimestamp("-1:0"))
    XCTAssertNil(NMOSTimestamp("1:2:3"))
  }

  func testOrdersBySecondsThenNanoseconds() {
    let early = NMOSTimestamp(seconds: 10, nanoseconds: 999_999_999)
    XCTAssertLessThan(NMOSTimestamp(seconds: 10, nanoseconds: 5), early)
    XCTAssertLessThan(early, NMOSTimestamp(seconds: 11))
    XCTAssertEqual(early.next, NMOSTimestamp(seconds: 11))
    XCTAssertEqual(NMOSTimestamp(seconds: 11).next, NMOSTimestamp(seconds: 11, nanoseconds: 1))
  }

  func testIsTAI() {
    let date = Date(timeIntervalSince1970: 1_700_000_000.25)
    let timestamp = NMOSTimestamp(date)
    XCTAssertEqual(timestamp.seconds, 1_700_000_037)
    XCTAssertEqual(timestamp.nanoseconds, 250_000_000)
    XCTAssertEqual(timestamp.date.timeIntervalSince1970, 1_700_000_000.25, accuracy: 1e-6)
  }

  func testCodesAsAString() throws {
    let data = try JSONEncoder().encode(["version": NMOSTimestamp(seconds: 1, nanoseconds: 2)])
    XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"version":"1:2"}"#)
    XCTAssertEqual(
      try JSONDecoder().decode([String: NMOSTimestamp].self, from: data)["version"],
      NMOSTimestamp(seconds: 1, nanoseconds: 2)
    )
  }
}
