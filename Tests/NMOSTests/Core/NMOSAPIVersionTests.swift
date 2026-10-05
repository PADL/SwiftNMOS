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

final class NMOSAPIVersionTests: XCTestCase {
  func testParsesAndDescribes() {
    XCTAssertEqual(NMOSAPIVersion("v1.3"), .v1_3)
    XCTAssertEqual(NMOSAPIVersion.v1_3.description, "v1.3")
    XCTAssertNil(NMOSAPIVersion("1.3"))
    XCTAssertNil(NMOSAPIVersion("v1"))
    XCTAssertNil(NMOSAPIVersion("v1.x"))
    XCTAssertNil(NMOSAPIVersion("v1.3.1"))
  }

  func testComparesFieldsAsIntegers() throws {
    let v1_5 = try XCTUnwrap(NMOSAPIVersion("v1.5"))
    let v1_12 = try XCTUnwrap(NMOSAPIVersion("v1.12"))
    XCTAssertLessThan(v1_5, v1_12)
    XCTAssertLessThan(v1_12, NMOSAPIVersion(major: 2, minor: 0))
  }

  func testCodesAsAString() throws {
    let data = try JSONEncoder().encode([NMOSAPIVersion.v1_3])
    XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["v1.3"]"#)
    XCTAssertEqual(try JSONDecoder().decode([NMOSAPIVersion].self, from: data), [.v1_3])
    XCTAssertThrowsError(try JSONDecoder().decode([NMOSAPIVersion].self, from: Data(#"["1.3"]"#.utf8)))
  }
}
