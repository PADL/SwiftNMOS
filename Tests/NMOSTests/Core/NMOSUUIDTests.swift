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

final class NMOSUUIDTests: XCTestCase {
  private let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!

  func testVersion5MatchesTheReferenceImplementation() {
    // Python: uuid.uuid5(uuid.NAMESPACE_DNS, "www.example.com")
    let uuid = UUID(version5: "www.example.com", namespace: dnsNamespace)
    XCTAssertEqual(uuid.nmosString, "2ed6657d-e927-568b-95e1-2665a8aea6a2")
  }

  func testVersion5IsDeterministicAndNameSensitive() {
    let first = UUID(version5: "sender/1", namespace: dnsNamespace)
    XCTAssertEqual(first, UUID(version5: "sender/1", namespace: dnsNamespace))
    XCTAssertNotEqual(first, UUID(version5: "sender/2", namespace: dnsNamespace))
    XCTAssertNotEqual(first, UUID(version5: "sender/1", namespace: first))
  }

  func testIDsAreWrittenInLowerCase() throws {
    let id = NMOSID(UUID(uuidString: "3B8BE755-08FF-452B-B217-C9151EB21193")!)
    let data = try JSONEncoder().encode([id])
    XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["3b8be755-08ff-452b-b217-c9151eb21193"]"#)
    XCTAssertEqual(try JSONDecoder().decode([NMOSID].self, from: data), [id])
    XCTAssertNil(NMOSID("not-a-uuid"))
  }

  func testAnIDIsWrittenAsFoundationWritesItInLowerCase() {
    for _ in 0..<200 {
      let uuid = UUID()
      XCTAssertEqual(uuid.nmosString, uuid.uuidString.lowercased())
    }
  }

  func testIDsAreOrderedAsTheyAreWritten() {
    let ids = (0..<200).map { _ in NMOSID(UUID()) }
    XCTAssertEqual(ids.sorted().map(\.description), ids.map(\.description).sorted())
    let id = ids[0]
    XCTAssertFalse(id < id)
  }
}
