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

/// One of the transport-parameter schemas in the package's `schemas/` directory, and a
/// check of a value against it. Only the keywords those schemas use are understood
/// (`type`, `properties`, `additionalProperties`, `anyOf`, `not`, `pattern`, `minimum`,
/// `maximum`); any other fails the check, so a schema cannot outgrow it unnoticed.
struct TransportParamsSchema {
  let name: String
  let root: NMOSJSONValue

  init(_ name: String) throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("schemas/\(name).json")
    self.name = name
    root = try JSONDecoder().decode(NMOSJSONValue.self, from: Data(contentsOf: url))
  }

  /// The parameters the schema describes.
  var properties: Set<String> { Set(root["properties"]?.objectValue.map { Array($0.keys) } ?? []) }

  /// The pattern a parameter's string value must match.
  func pattern(of property: String) -> String? {
    let schema = root["properties"]?[property]
    return schema?["pattern"]?.stringValue
      ?? schema?["anyOf"]?.arrayValue?.lazy.compactMap { $0["pattern"]?.stringValue }.first
  }

  /// Fails the test with each way `value` does not meet the schema.
  func check(_ value: NMOSJSONValue?, file: StaticString = #filePath, line: UInt = #line) {
    guard let value else { return XCTFail("\(name): no value", file: file, line: line) }
    for failure in Self.failures(value, root, at: name) {
      XCTFail(failure, file: file, line: line)
    }
  }

  private static let keywords: Set = [
    "$schema", "title", "description", "type", "properties", "additionalProperties", "anyOf", "not",
    "pattern", "minimum", "maximum",
  ]

  private static func failures(_ value: NMOSJSONValue, _ schema: NMOSJSONValue, at path: String) -> [String] {
    guard let keys = schema.objectValue?.keys else { return ["\(path): the schema is not an object"] }
    let unknown = Set(keys).subtracting(keywords)
    guard unknown.isEmpty else { return ["\(path): the schema uses \(unknown.sorted())"] }
    var failures = [String]()
    if let types = schema["type"], !matches(value, types) { failures.append("\(path): \(value) is not \(types)") }
    if let anyOf = schema["anyOf"]?.arrayValue,
       !anyOf.contains(where: { Self.failures(value, $0, at: path).isEmpty })
    {
      failures.append("\(path): \(value) meets none of anyOf")
    }
    if let not = schema["not"], Self.failures(value, not, at: path).isEmpty {
      failures.append("\(path): \(value) meets the schema it must not")
    }
    failures += scalarFailures(value, schema, at: path)
    failures += objectFailures(value, schema, at: path)
    return failures
  }

  private static func matches(_ value: NMOSJSONValue, _ types: NMOSJSONValue) -> Bool {
    (types.arrayValue ?? [types]).contains { type in
      switch (type.stringValue, value) {
      case ("null", .null), ("boolean", .bool), ("integer", .integer), ("number", .integer), ("number", .number),
           ("string", .string), ("array", .array), ("object", .object): true
      default: false
      }
    }
  }

  private static func scalarFailures(_ value: NMOSJSONValue, _ schema: NMOSJSONValue, at path: String) -> [String] {
    var failures = [String]()
    if let pattern = schema["pattern"]?.stringValue, let string = value.stringValue,
       string.range(of: pattern, options: .regularExpression) == nil
    {
      failures.append("\(path): \"\(string)\" does not match \(pattern)")
    }
    if let minimum = schema["minimum"]?.doubleValue, let number = value.doubleValue, number < minimum {
      failures.append("\(path): \(number) is below \(minimum)")
    }
    if let maximum = schema["maximum"]?.doubleValue, let number = value.doubleValue, number > maximum {
      failures.append("\(path): \(number) is above \(maximum)")
    }
    return failures
  }

  private static func objectFailures(_ value: NMOSJSONValue, _ schema: NMOSJSONValue, at path: String) -> [String] {
    guard let object = value.objectValue else { return [] }
    let properties = schema["properties"]?.objectValue ?? [:]
    var failures = [String]()
    for (key, member) in object {
      if let property = properties[key] {
        failures += Self.failures(member, property, at: "\(path).\(key)")
      } else if schema["additionalProperties"] == false {
        failures.append("\(path): `\(key)` is not a property the schema allows")
      }
    }
    return failures
  }
}
