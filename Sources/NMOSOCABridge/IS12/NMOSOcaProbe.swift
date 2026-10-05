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
import SwiftOCA

/// What a Codable type asks its decoder for, which is its structure: the keys and types
/// of its fields, or the one value it wraps. The type is decoded from nothing, each
/// request answered with an empty value, so no instance or sample data is needed.
final class NMOSOcaProbe {
  private(set) var fields = [(key: String, type: Any.Type, isOptional: Bool)]()
  /// The type a single-value container was asked for.
  private(set) var single: Any.Type?
  /// Set when the type decodes in a way a struct descriptor cannot express.
  private(set) var isIrregular = false

  fileprivate func record(_ key: any CodingKey, _ type: Any.Type, isOptional: Bool) {
    if !fields.contains(where: { $0.key == key.stringValue }) {
      fields.append((key.stringValue, type, isOptional))
    }
  }

  fileprivate func record(single type: Any.Type) { single = type }
  fileprivate func recordIrregular() { isIrregular = true }

  /// An empty value of the type, recording what the type itself asks for in `probe`.
  /// A value that needs particular contents to exist (an enumeration without a zero
  /// case) is found by trying the small integers in turn.
  static func value<T: Decodable>(_ type: T.Type, recording probe: NMOSOcaProbe? = nil) throws -> T {
    if let optional = type as? any ExpressibleByNilLiteral.Type,
       let none = optional.init(nilLiteral: ()) as? T
    {
      return none
    }
    if let empty = empties[ObjectIdentifier(type)] as? T { return empty }
    do {
      return try T(from: ProbeDecoder(probe: probe, seed: 0))
    } catch {
      guard type is any RawRepresentable.Type else { throw error }
      for seed in 1...255 {
        if let value = try? T(from: ProbeDecoder(probe: nil, seed: seed)) { return value }
      }
      throw error
    }
  }
}

/// Empty values of the types OCP.2 marshals in a form of its own, which do not decode
/// from nothing.
private let empties: [ObjectIdentifier: any Sendable] = [
  ObjectIdentifier(Data.self): Data(),
  ObjectIdentifier(OcaBlob.self): OcaBlob(),
  ObjectIdentifier(OcaLongBlob.self): OcaLongBlob(),
  ObjectIdentifier(OcaPropertyID.self): OcaPropertyID(defLevel: 1, propertyIndex: 1),
  ObjectIdentifier(OcaMethodID.self): OcaMethodID(defLevel: 1, methodIndex: 1),
  ObjectIdentifier(OcaEventID.self): OcaEventID(defLevel: 1, eventIndex: 1),
  ObjectIdentifier(OcaClassID.self): SwiftOCA.OcaRoot.classID,
  ObjectIdentifier(OcaOrganizationID.self): OcaOrganizationID(),
]

private struct ProbeError: Error {}

private struct ProbeDecoder: Decoder {
  let probe: NMOSOcaProbe?
  /// The value every integer decodes as.
  let seed: Int

  var codingPath: [any CodingKey] { [] }
  var userInfo: [CodingUserInfoKey: Any] { [:] }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    KeyedDecodingContainer(ProbeKeyedContainer<Key>(probe: probe, seed: seed))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    // an array, or a type that writes itself as one; either way it is left empty
    probe?.recordIrregular()
    return ProbeUnkeyedContainer()
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    ProbeSingleValueContainer(probe: probe, seed: seed)
  }
}

private struct ProbeKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let probe: NMOSOcaProbe?
  let seed: Int

  var codingPath: [any CodingKey] { [] }
  var allKeys: [Key] { [] }

  func contains(_ key: Key) -> Bool { true }
  func decodeNil(forKey key: Key) throws -> Bool { false }

  private func field<T>(_ key: Key, _ value: T) -> T {
    probe?.record(key, T.self, isOptional: false)
    return value
  }

  private func optionalField<T>(_ key: Key, _ type: T.Type) -> T? {
    probe?.record(key, T.self, isOptional: true)
    return nil
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { field(key, false) }
  func decode(_ type: String.Type, forKey key: Key) throws -> String { field(key, "") }
  func decode(_ type: Double.Type, forKey key: Key) throws -> Double { field(key, 0) }
  func decode(_ type: Float.Type, forKey key: Key) throws -> Float { field(key, 0) }
  func decode(_ type: Int.Type, forKey key: Key) throws -> Int { field(key, seed) }
  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { field(key, Int8(seed & 0x7F)) }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { field(key, Int16(seed)) }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { field(key, Int32(seed)) }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { field(key, Int64(seed)) }
  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { field(key, UInt(seed)) }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { field(key, UInt8(seed)) }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { field(key, UInt16(seed)) }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { field(key, UInt32(seed)) }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { field(key, UInt64(seed)) }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    probe?.record(key, T.self, isOptional: false)
    return try NMOSOcaProbe.value(type)
  }

  func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { optionalField(key, type) }
  func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { optionalField(key, type) }
  func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { optionalField(key, type) }
  func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { optionalField(key, type) }
  func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { optionalField(key, type) }
  func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { optionalField(key, type) }
  func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { optionalField(key, type) }
  func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { optionalField(key, type) }
  func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { optionalField(key, type) }
  func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { optionalField(key, type) }
  func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { optionalField(key, type) }
  func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { optionalField(key, type) }
  func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { optionalField(key, type) }
  func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { optionalField(key, type) }

  func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
    optionalField(key, type)
  }

  func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type,
    forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> {
    probe?.recordIrregular()
    throw ProbeError()
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    probe?.recordIrregular()
    throw ProbeError()
  }

  func superDecoder() throws -> any Decoder { throw ProbeError() }
  func superDecoder(forKey key: Key) throws -> any Decoder { throw ProbeError() }
}

/// An empty sequence: what an array, or a type that decodes like one, is given.
private struct ProbeUnkeyedContainer: UnkeyedDecodingContainer {
  var codingPath: [any CodingKey] { [] }
  var count: Int? { 0 }
  var isAtEnd: Bool { true }
  var currentIndex: Int { 0 }

  mutating func decodeNil() throws -> Bool { throw ProbeError() }
  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { throw ProbeError() }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type
  ) throws -> KeyedDecodingContainer<NestedKey> {
    throw ProbeError()
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { throw ProbeError() }
  mutating func superDecoder() throws -> any Decoder { throw ProbeError() }
}

private struct ProbeSingleValueContainer: SingleValueDecodingContainer {
  let probe: NMOSOcaProbe?
  let seed: Int

  var codingPath: [any CodingKey] { [] }

  private func single<T>(_ value: T) -> T {
    probe?.record(single: T.self)
    return value
  }

  func decodeNil() -> Bool { false }
  func decode(_ type: Bool.Type) throws -> Bool { single(false) }
  func decode(_ type: String.Type) throws -> String { single("") }
  func decode(_ type: Double.Type) throws -> Double { single(0) }
  func decode(_ type: Float.Type) throws -> Float { single(0) }
  func decode(_ type: Int.Type) throws -> Int { single(seed) }
  func decode(_ type: Int8.Type) throws -> Int8 { single(Int8(seed & 0x7F)) }
  func decode(_ type: Int16.Type) throws -> Int16 { single(Int16(seed)) }
  func decode(_ type: Int32.Type) throws -> Int32 { single(Int32(seed)) }
  func decode(_ type: Int64.Type) throws -> Int64 { single(Int64(seed)) }
  func decode(_ type: UInt.Type) throws -> UInt { single(UInt(seed)) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { single(UInt8(seed)) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { single(UInt16(seed)) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { single(UInt32(seed)) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { single(UInt64(seed)) }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    probe?.record(single: T.self)
    return try NMOSOcaProbe.value(type)
  }
}
