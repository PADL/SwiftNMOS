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

final class NMOSJSONValueTests: XCTestCase {
  func testWholeNumbersStayIntegers() throws {
    // beyond the 53 bits a double holds exactly
    let text = #"{"counter":9223372036854775807,"gain":-6.5,"port":5004}"#
    let json = try NMOSJSONValue(data: Data(text.utf8))
    XCTAssertEqual(json["counter"], .integer(.max))
    XCTAssertEqual(json["gain"], .number(-6.5))
    XCTAssertEqual(json["port"]?.integerValue, 5004)
    XCTAssertEqual(String(decoding: try json.data(), as: UTF8.self), text)
  }

  func testDistinguishesBooleansFromNumbers() throws {
    let json = try NMOSJSONValue(data: Data(#"[true,1,0,false,null,"1"]"#.utf8))
    XCTAssertEqual(json, [true, 1, 0, false, .null, "1"])
    XCTAssertNil(json.arrayValue?[1].boolValue)
  }

  func testRoundTripsNestedValues() throws {
    let json: NMOSJSONValue = ["a": [1, 2.5, ["b": .null]], "c": "d", "e": [:], "f": []]
    XCTAssertEqual(try NMOSJSONValue(data: json.data()), json)
  }

  func testConvertsToAndFromCodableValues() throws {
    struct Activation: Codable, Equatable {
      var mode: String?
      var requested_time: String?
    }
    let json = try NMOSJSONValue(encoding: Activation(mode: "activate_immediate"))
    XCTAssertEqual(json, ["mode": "activate_immediate"])
    XCTAssertEqual(try json.decode(Activation.self), Activation(mode: "activate_immediate"))
  }

  func testDoesNotEscapeSlashes() throws {
    let json: NMOSJSONValue = ["href": "http://10.0.0.1/x-nmos/"]
    XCTAssertEqual(String(decoding: try json.data(), as: UTF8.self), #"{"href":"http://10.0.0.1/x-nmos/"}"#)
  }
}
