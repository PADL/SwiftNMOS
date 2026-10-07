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
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// How the values of a Swift type appear in MS-05-02. They are the type's OCP.2 form
/// except where MS-05-02 has no way to describe that form: a map becomes a sequence
/// of key and value structs, and a class ID's authority is spelled out as numbers.
indirect enum NMOSOcaSchema: Sendable, Hashable {
  case bool
  /// An integer, with the MS-05-02 primitive wide enough for it.
  case integer(String)
  case float(String)
  case string
  /// Base64 text, as OCP.2 writes every blob.
  case blob
  case organizationID
  /// A property, method or event ID: `[level, index]`.
  case elementID
  case classID
  /// An OCA object number, which is presented as the oid of the object it names.
  case objectNumber
  case enumeration(String)
  case structure(String)
  case sequence(NMOSOcaSchema)
  case optional(NMOSOcaSchema)
  /// A map, by the name of the struct that holds one of its entries.
  case map(String, key: NMOSOcaSchema, value: NMOSOcaSchema)
}

extension NMOSOcaSchema {
  /// Whether a value of the schema is one plain value, which is never absent.
  private var isPlain: Bool {
    switch self {
    case .bool, .integer, .float, .string, .enumeration, .objectNumber: true
    default: false
    }
  }

  /// Whether a value of the schema is a number, which a range can constrain.
  var isNumber: Bool {
    switch self {
    case .integer, .float: true
    default: false
    }
  }
}

/// How a property or field of some schema is described: MS-05-02 puts sequences and
/// nullability in the descriptor of what holds the value, not in the datatype.
struct NMOSOcaTypeReference: Sendable, Hashable {
  var typeName: String
  var isSequence = false
  var isNullable = false
}

/// A type MS-05-02 cannot describe, so a property of that type is not presented.
private struct NMOSOcaUnsupportedType: Error, CustomStringConvertible {
  let description: String

  init(_ type: Any.Type, _ reason: String) {
    description = "\(type): \(reason)"
  }
}

/// The datatypes of the properties a device presents, worked out from the Swift types
/// themselves, and the conversion of their values between OCP.2 and MS-05-02 forms.
@OcaDevice
final class NMOSOcaDatatypes {
  private var schemas = [ObjectIdentifier: Result<NMOSOcaSchema, NMOSOcaUnsupportedType>]()
  private var inProgress = Set<ObjectIdentifier>()
  private var names = [String: ObjectIdentifier]()
  private var fields = [String: [(name: String, schema: NMOSOcaSchema)]]()
  /// The descriptors of every datatype met so far, in the order they were met.
  private(set) var descriptors = [NcDatatypeDescriptor]()
  /// Which oid each object number is presented as.
  private let mapping: NMOSOcaControlMapping

  nonisolated init(mapping: NMOSOcaControlMapping = .standard) {
    self.mapping = mapping
  }

  // MARK: - Schemas

  func schema(of type: Any.Type) throws -> NMOSOcaSchema {
    let id = ObjectIdentifier(type)
    if let known = schemas[id] { return try known.get() }
    guard inProgress.insert(id).inserted else {
      throw NMOSOcaUnsupportedType(type, "a type that contains itself")
    }
    defer { inProgress.remove(id) }
    let result = Result { try derive(type) }.mapError {
      $0 as? NMOSOcaUnsupportedType ?? NMOSOcaUnsupportedType(type, "\($0)")
    }
    schemas[id] = result
    return try result.get()
  }

  private func derive(_ type: Any.Type) throws -> NMOSOcaSchema {
    if let primitive = Self.primitives[ObjectIdentifier(type)] { return primitive }
    if let optional = type as? any OptionalType.Type {
      return try .optional(schema(of: optional.wrapped))
    }
    if let map = type as? any MapType.Type {
      let key = try schema(of: map.key), value = try schema(of: map.value)
      let name = try name(for: type)
      try define(structure: name, fields: [("Key", key), ("Value", value)])
      return .map(name, key: key, value: value)
    }
    if let sequence = type as? any SequenceType.Type {
      return try .sequence(schema(of: sequence.element))
    }
    if type is any Ocp1TypedBlobRepresentable.Type { return .blob }
    // a device object is written as its object number
    if type is SwiftOCADevice.OcaRoot.Type { return .objectNumber }
    if let enumeration = type as? any (CaseIterable & RawRepresentable).Type,
       let items = Self.items(of: enumeration)
    {
      let name = try name(for: type)
      descriptors.append(.init(name: name, kind: .enum(items: items)))
      return .enumeration(name)
    }
    if let raw = type as? any RawRepresentable.Type {
      return try schema(of: Self.rawType(of: raw))
    }
    guard type is any Codable.Type else {
      throw NMOSOcaUnsupportedType(type, "not Codable")
    }

    // a struct whose coding is synthesised is coded as its stored properties; one that
    // codes otherwise is a primitive above, or has a field MS-05-02 cannot describe
    let fields = Ocp2Encoder.fields(of: type)
    guard !fields.isEmpty else {
      throw NMOSOcaUnsupportedType(type, "not a struct of named fields")
    }
    let name = try name(for: type)
    try define(structure: name, fields: fields.map { field in
      try (Ocp2Encoder.fieldName(field.name), schema(of: field.type))
    })
    return .structure(name)
  }

  private static let primitives: [ObjectIdentifier: NMOSOcaSchema] = [
    ObjectIdentifier(Bool.self): .bool,
    ObjectIdentifier(String.self): .string,
    // MS-05-02 has no 8-bit integers
    ObjectIdentifier(Int8.self): .integer("NcInt16"),
    ObjectIdentifier(Int16.self): .integer("NcInt16"),
    ObjectIdentifier(Int32.self): .integer("NcInt32"),
    ObjectIdentifier(Int64.self): .integer("NcInt64"),
    ObjectIdentifier(Int.self): .integer("NcInt64"),
    ObjectIdentifier(UInt8.self): .integer("NcUint16"),
    ObjectIdentifier(UInt16.self): .integer("NcUint16"),
    ObjectIdentifier(UInt32.self): .integer("NcUint32"),
    ObjectIdentifier(UInt64.self): .integer("NcUint64"),
    ObjectIdentifier(UInt.self): .integer("NcUint64"),
    ObjectIdentifier(Float.self): .float("NcFloat32"),
    ObjectIdentifier(Double.self): .float("NcFloat64"),
    ObjectIdentifier(Data.self): .blob,
    ObjectIdentifier(OcaBlob.self): .blob,
    ObjectIdentifier(OcaLongBlob.self): .blob,
    ObjectIdentifier(OcaPropertyID.self): .elementID,
    ObjectIdentifier(OcaMethodID.self): .elementID,
    ObjectIdentifier(OcaEventID.self): .elementID,
    ObjectIdentifier(OcaClassID.self): .classID,
    ObjectIdentifier(OcaONo.self): .objectNumber,
    ObjectIdentifier(OcaOrganizationID.self): .organizationID,
  ]

  private static func items<E: CaseIterable & RawRepresentable>(of type: E.Type) -> [NcEnumItemDescriptor]? {
    var items = [NcEnumItemDescriptor]()
    for item in type.allCases {
      guard let value = (item.rawValue as? any BinaryInteger).flatMap({ UInt16(exactly: $0) }) else {
        return nil
      }
      items.append(.init(name: "\(item)", value: value))
    }
    return items.isEmpty ? nil : items
  }

  private static func rawType<R: RawRepresentable>(of type: R.Type) -> Any.Type { R.RawValue.self }

  // MARK: - Names and descriptors

  /// An MS-05-02 name for a Swift type: its own name, without what a name cannot hold.
  private static func name(of type: Any.Type) -> String {
    var name = String(String(describing: type).map { $0.isLetter || $0.isNumber ? $0 : "_" })
    while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
    name = name.trimmingCharacters(in: ["_"])
    // a map is described by the struct that holds one of its entries
    if name.hasPrefix("Dictionary_") { name = "OcaMapItem_" + name.dropFirst("Dictionary_".count) }
    // only the standard's own models can be named Nc
    if name.hasPrefix("Nc") { name = "Oca" + name }
    return name
  }

  /// The type's name, which no other type may have.
  private func name(for type: Any.Type) throws -> String {
    let name = Self.name(of: type)
    if let other = names[name], other != ObjectIdentifier(type) {
      throw NMOSOcaUnsupportedType(type, "another type is already named \(name)")
    }
    names[name] = ObjectIdentifier(type)
    return name
  }

  /// `parentType` is the struct this one extends: a method's result derives from `NcMethodResult`.
  private func define(
    structure name: String,
    fields: [(name: String, schema: NMOSOcaSchema)],
    parentType: String? = nil
  ) throws {
    let descriptors = try fields.map { field in
      let reference = try reference(to: field.schema)
      return NcFieldDescriptor(
        name: field.name, typeName: reference.typeName,
        isNullable: reference.isNullable, isSequence: reference.isSequence
      )
    }
    self.fields[name] = fields
    self.descriptors.append(.init(name: name, kind: .struct(fields: descriptors, parentType: parentType)))
  }

  /// The result type of a method: a struct derived from `NcMethodResult` with the
  /// method's results as fields, or `NcMethodResult` itself for a method with none.
  func methodResult(named name: String, fields: [(name: String, schema: NMOSOcaSchema)]) throws -> String {
    guard !fields.isEmpty else { return "NcMethodResult" }
    if self.fields[name] != nil { return name }
    guard names[name] == nil else { throw NMOSOcaUnsupportedType(Any.self, "a type is already named \(name)") }
    try define(structure: name, fields: fields, parentType: "NcMethodResult")
    return name
  }

  private func typedef(_ name: String, of parent: String, isSequence: Bool = false) -> String {
    if !descriptors.contains(where: { $0.name == name }) {
      descriptors.append(.init(name: name, kind: .typedef(parentType: parent, isSequence: isSequence)))
    }
    return name
  }

  /// How a property or field holding a value of this schema names its type.
  func reference(to schema: NMOSOcaSchema) throws -> NMOSOcaTypeReference {
    switch schema {
    case .bool: return .init(typeName: "NcBoolean")
    case let .integer(name), let .float(name): return .init(typeName: name)
    case .string: return .init(typeName: "NcString")
    case .blob: return .init(typeName: typedef("OcaBlob", of: "NcString"))
    case .organizationID: return .init(typeName: typedef("OcaOrganizationID", of: "NcString"))
    case .elementID: return .init(typeName: typedef("OcaElementID", of: "NcUint16", isSequence: true))
    case .classID: return .init(typeName: typedef("OcaClassID", of: "NcUint16", isSequence: true))
    case .objectNumber: return .init(typeName: "NcOid")
    case let .enumeration(name), let .structure(name): return .init(typeName: name)
    case let .map(name, _, _): return .init(typeName: name, isSequence: true)
    case let .optional(wrapped):
      var reference = try reference(to: wrapped)
      reference.isNullable = true
      return reference
    case let .sequence(element):
      var reference = try reference(to: element)
      guard !reference.isNullable else {
        throw NMOSOcaUnsupportedType(Any.self, "a sequence whose items can be null")
      }
      if reference.isSequence {
        // a sequence of sequences needs the inner one to have a name
        reference.typeName = typedef(reference.typeName + "List", of: reference.typeName, isSequence: true)
      }
      reference.isSequence = true
      return reference
    }
  }

  // MARK: - Values

  /// The MS-05-02 form of an OCP.2 value. Throws if the value is not of the schema,
  /// which means the schema was derived wrongly and the value must not be presented.
  func standard(from oca: NMOSJSONValue, as schema: NMOSOcaSchema) throws -> NMOSJSONValue {
    func mismatch() -> NMOSOcaValueError { NMOSOcaValueError(schema: schema, value: oca) }

    switch schema {
    case .bool:
      guard oca.boolValue != nil else { throw mismatch() }
      return oca
    case .integer, .enumeration:
      guard let value = oca.integerValue else { throw mismatch() }
      return .integer(value)
    case .objectNumber:
      guard let value = oca.integerValue.flatMap(OcaONo.init(exactly:)) else { throw mismatch() }
      return .integer(Int64(mapping.oid(of: value)))
    case let .float(name):
      if let value = oca.doubleValue { return .number(value) }
      // OCP.2 writes what JSON has no number for as text; MS-05-02 has only numbers
      let limit = name == "NcFloat32" ? Double(Float.greatestFiniteMagnitude) : Double.greatestFiniteMagnitude
      switch oca.stringValue {
      case "Infinity", "+Infinity": return .number(limit)
      case "-Infinity": return .number(-limit)
      case "NaN": return .number(0)
      default: throw mismatch()
      }
    case .string, .blob, .organizationID:
      guard oca.stringValue != nil else { throw mismatch() }
      return oca
    case .elementID:
      guard let items = oca.arrayValue, items.count == 2, items.allSatisfy({ $0.integerValue != nil })
      else { throw mismatch() }
      return oca
    case .classID:
      guard let items = oca.arrayValue else { throw mismatch() }
      return try .array(items.flatMap { item -> [NMOSJSONValue] in
        if item.integerValue != nil { return [item] }
        // [65535, "0AE91B"]: the proprietary marker and the authority it introduces
        guard let pair = item.arrayValue, pair.count == 2, let marker = pair[0].integerValue,
              let authority = pair[1].stringValue.flatMap({ Int64($0, radix: 16) })
        else { throw mismatch() }
        return [.integer(marker), .integer(authority >> 16), .integer(authority & 0xFFFF)]
      })
    case let .structure(name):
      guard let object = oca.objectValue, let fields = fields[name] else { throw mismatch() }
      return try .object(Dictionary(uniqueKeysWithValues: fields.map { field in
        try (field.name, standard(from: object[field.name] ?? .null, as: field.schema))
      }))
    case let .sequence(element):
      guard let items = oca.arrayValue else { throw mismatch() }
      return try .array(items.map { try standard(from: $0, as: element) })
    case let .optional(wrapped):
      return oca.isNull ? .null : try standard(from: oca, as: wrapped)
    case let .map(_, key, value):
      guard let entries = oca.arrayValue else { throw mismatch() }
      return try .array(entries.map { entry in
        guard let pair = entry.arrayValue, pair.count == 2 else { throw mismatch() }
        return try ["Key": standard(from: pair[0], as: key), "Value": standard(from: pair[1], as: value)]
      })
    }
  }

  /// The OCP.2 form of a value a controller supplied, for the OCA setter to decode.
  func oca(from standard: NMOSJSONValue, as schema: NMOSOcaSchema) throws -> NMOSJSONValue {
    func mismatch() -> NMOSOcaValueError { NMOSOcaValueError(schema: schema, value: standard) }

    switch schema {
    case .bool:
      guard standard.boolValue != nil else { throw mismatch() }
    case .integer, .enumeration:
      guard standard.integerValue != nil else { throw mismatch() }
    case .objectNumber:
      guard let oid = standard.integerValue.flatMap(NcOid.init(exactly:)) else { throw mismatch() }
      return .integer(Int64(mapping.objectNumber(of: oid)))
    case .float:
      guard standard.doubleValue != nil else { throw mismatch() }
    case .string, .blob, .organizationID:
      guard standard.stringValue != nil else { throw mismatch() }
    case .elementID:
      guard standard.arrayValue?.allSatisfy({ $0.integerValue != nil }) == true else { throw mismatch() }
    case .classID:
      // the proprietary marker and the two fields after it go back to OCP.2's
      // [65535, "0AE91B"], as `standard(from:)` read them
      guard let fields = standard.arrayValue?.compactMap(\.integerValue),
            fields.count == standard.arrayValue?.count
      else { throw mismatch() }
      var items = [NMOSJSONValue]()
      var index = fields.startIndex
      while index < fields.endIndex {
        if fields[index] == 0xFFFF, index + 2 < fields.endIndex {
          let authority = fields[index + 1] << 16 | fields[index + 2]
          items.append(.array([.integer(0xFFFF), .string(String(format: "%06X", authority))]))
          index += 3
        } else {
          items.append(.integer(fields[index]))
          index += 1
        }
      }
      return .array(items)
    case let .structure(name):
      guard let object = standard.objectValue, let fields = fields[name] else { throw mismatch() }
      return try .object(Dictionary(uniqueKeysWithValues: fields.map { field in
        guard let value = object[field.name] else { throw mismatch() }
        return try (field.name, oca(from: value, as: field.schema))
      }))
    case let .sequence(element):
      guard let items = standard.arrayValue else { throw mismatch() }
      return try .array(items.map { try oca(from: $0, as: element) })
    case let .optional(wrapped):
      return standard.isNull ? .null : try oca(from: standard, as: wrapped)
    case let .map(_, key, value):
      // a sequence may hold a key twice and a map cannot: the first entry for a key is kept
      guard let entries = standard.arrayValue else { throw mismatch() }
      var keys = Set<NMOSJSONValue>()
      return try .array(entries.compactMap { entry in
        guard let entryKey = entry["Key"], let entryValue = entry["Value"] else { throw mismatch() }
        let ocaKey = try oca(from: entryKey, as: key)
        guard keys.insert(ocaKey).inserted else { return nil }
        return try [ocaKey, oca(from: entryValue, as: value)]
      })
    }
    return standard
  }
}

/// A value that is not of the schema its type was given.
private struct NMOSOcaValueError: Error, CustomStringConvertible {
  let schema: NMOSOcaSchema
  let value: NMOSJSONValue

  var description: String { "\(value) is not \(schema)" }
}

// MARK: - OCP.2 values

extension NMOSJSONValue {
  /// A value as SwiftOCA's OCP.2 encoder leaves it: Swift scalars, arrays and
  /// dictionaries keyed by string.
  init(ocp2 value: Any) throws {
    switch value {
    case is NSNull: self = .null
    case let value as Bool: self = .bool(value)
    case let value as Int: self = .integer(Int64(value))
    case let value as Int64: self = .integer(value)
    case let value as UInt64: self = Int64(exactly: value).map(NMOSJSONValue.integer) ?? .number(Double(value))
    case let value as Double: self = .number(value)
    case let value as Float: self = .number(Double(value))
    case let value as String: self = .string(value)
    case let value as [Any]: self = try .array(value.map(NMOSJSONValue.init(ocp2:)))
    case let value as [String: Any]: self = try .object(value.mapValues(NMOSJSONValue.init(ocp2:)))
    default: throw NMOSOcaUnsupportedType(type(of: value), "not an OCP.2 value")
    }
  }

  /// The value as the OCP.2 decoder takes it.
  var ocp2: Any {
    switch self {
    case .null: NSNull()
    case let .bool(value): value
    case let .integer(value): Int(value)
    case let .number(value): value
    case let .string(value): value
    case let .array(value): value.map(\.ocp2)
    case let .object(value): value.mapValues(\.ocp2)
    }
  }
}

// MARK: - Containers

/// The standard library's containers, asked what they contain without a value of them.
private protocol OptionalType {
  static var wrapped: Any.Type { get }
}

extension Optional: OptionalType {
  static var wrapped: Any.Type { Wrapped.self }
}

private protocol SequenceType {
  static var element: Any.Type { get }
}

extension Array: SequenceType {
  static var element: Any.Type { Element.self }
}

extension Set: SequenceType {
  static var element: Any.Type { Element.self }
}

private protocol MapType {
  static var key: Any.Type { get }
  static var value: Any.Type { get }
}

extension Dictionary: MapType {
  static var key: Any.Type { Key.self }
  static var value: Any.Type { Value.self }
}
