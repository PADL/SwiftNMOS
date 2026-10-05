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

/// A JSON value of no fixed shape: IS-05 transport parameters, IS-12 property values and
/// method arguments. Whole numbers stay integers, so a 64-bit counter is not rounded.
public enum NMOSJSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([NMOSJSONValue])
  case object([String: NMOSJSONValue])
}

extension NMOSJSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([NMOSJSONValue].self) {
      self = .array(value)
    } else {
      self = try .object(container.decode([String: NMOSJSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case let .bool(value): try container.encode(value)
    case let .integer(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .string(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    }
  }
}

public extension NMOSJSONValue {
  /// Parses JSON text; a bare scalar is accepted as well as an object or array.
  init(data: Data) throws {
    self = try JSONDecoder().decode(NMOSJSONValue.self, from: data)
  }

  /// The value as JSON text, with object keys sorted so the output is reproducible.
  func data() throws -> Data {
    try NMOSJSONCoding.encoder.encode(self)
  }

  /// Re-encodes any Encodable value, such as a resource, as a JSON value.
  init(encoding value: some Encodable) throws {
    self = try NMOSJSONValue(data: NMOSJSONCoding.encoder.encode(value))
  }

  /// Decodes a typed value from this JSON value.
  func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: data())
  }

  var isNull: Bool { self == .null }

  var boolValue: Bool? {
    if case let .bool(value) = self { value } else { nil }
  }

  var stringValue: String? {
    if case let .string(value) = self { value } else { nil }
  }

  /// A whole number, including one that arrived with a fractional part of zero.
  var integerValue: Int64? {
    switch self {
    case let .integer(value): value
    case let .number(value): Int64(exactly: value)
    default: nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case let .integer(value): Double(value)
    case let .number(value): value
    default: nil
    }
  }

  var arrayValue: [NMOSJSONValue]? {
    if case let .array(value) = self { value } else { nil }
  }

  var objectValue: [String: NMOSJSONValue]? {
    if case let .object(value) = self { value } else { nil }
  }

  /// The member of an object, nil for a missing member or a value that is not an object.
  subscript(key: String) -> NMOSJSONValue? {
    objectValue?[key]
  }
}

// not ExpressibleByNilLiteral: `nil` would then mean `.null` wherever an optional
// NMOSJSONValue is inferred, instead of the absence of a value
extension NMOSJSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int64) { self = .integer(value) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: NMOSJSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, NMOSJSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

/// The JSON encoder every NMOS response and request body goes through.
public enum NMOSJSONCoding {
  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
