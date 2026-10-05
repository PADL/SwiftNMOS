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

/// MS-05-02 `NcClassId`: a class's lineage from `NcObject`, one index per level, with
/// an authority key (zero or negative) before the first non-standard class.
public typealias NcClassID = [Int32]

/// An MS-05-02 value as IS-12 marshals it. Every field of a struct is written, a
/// missing optional as null, since controllers validate values against descriptors.
public protocol NcJSONRepresentable {
  var json: NMOSJSONValue { get }
}

extension Optional where Wrapped == String {
  var json: NMOSJSONValue { map(NMOSJSONValue.string) ?? .null }
}

extension NcElementID: NcJSONRepresentable {
  public var json: NMOSJSONValue {
    ["level": .integer(Int64(level)), "index": .integer(Int64(index))]
  }

  /// Reads `{level, index}`; nil for anything else.
  public init?(json: NMOSJSONValue) {
    guard let level = json["level"]?.integerValue.flatMap(UInt16.init(exactly:)),
          let index = json["index"]?.integerValue.flatMap(UInt16.init(exactly:))
    else { return nil }
    self.init(level: level, index: index)
  }
}

public extension [Int32] {
  var json: NMOSJSONValue { .array(map { .integer(Int64($0)) }) }

  /// Reads an `NcClassId`; nil for anything but an array of 32-bit integers.
  init?(json: NMOSJSONValue) {
    guard let fields = json.arrayValue else { return nil }
    var classID = NcClassID()
    for field in fields {
      guard let value = field.integerValue.flatMap(Int32.init(exactly:)) else { return nil }
      classID.append(value)
    }
    self = classID
  }

  /// The class this one derives from; an authority key is not a class, so it goes too.
  var ncParent: NcClassID? {
    var parent = NcClassID(dropLast())
    while let last = parent.last, last <= 0 { parent.removeLast() }
    return parent.isEmpty ? nil : parent
  }

  /// Whether the class contains an authority key, as every non-standard class must.
  var isNonStandard: Bool { contains { $0 <= 0 } }

  /// The inheritance level of the class: the number of classes in its lineage.
  var ncLevel: UInt16 { UInt16(count { $0 > 0 }) }
}

/// MS-05-02 `NcPropertyDescriptor`.
public struct NcPropertyDescriptor: Sendable, Hashable, NcJSONRepresentable {
  public var description: String?
  public var id: NcElementID
  public var name: String
  /// Nil when the property can hold a value of any type.
  public var typeName: String?
  public var isReadOnly: Bool
  public var isNullable: Bool
  public var isSequence: Bool
  public var isDeprecated: Bool
  /// An `NcParameterConstraints` object, when the property has constraints.
  public var constraints: NMOSJSONValue?

  public init(
    description: String? = nil,
    id: NcElementID,
    name: String,
    typeName: String?,
    isReadOnly: Bool,
    isNullable: Bool = false,
    isSequence: Bool = false,
    isDeprecated: Bool = false,
    constraints: NMOSJSONValue? = nil
  ) {
    self.description = description
    self.id = id
    self.name = name
    self.typeName = typeName
    self.isReadOnly = isReadOnly
    self.isNullable = isNullable
    self.isSequence = isSequence
    self.isDeprecated = isDeprecated
    self.constraints = constraints
  }

  public var json: NMOSJSONValue {
    [
      "description": description.json, "id": id.json, "name": .string(name),
      "typeName": typeName.json, "isReadOnly": .bool(isReadOnly), "isNullable": .bool(isNullable),
      "isSequence": .bool(isSequence), "isDeprecated": .bool(isDeprecated),
      "constraints": constraints ?? .null,
    ]
  }
}

/// MS-05-02 `NcParameterDescriptor`.
public struct NcParameterDescriptor: Sendable, Hashable, NcJSONRepresentable {
  public var description: String?
  public var name: String
  public var typeName: String?
  public var isNullable: Bool
  public var isSequence: Bool
  public var constraints: NMOSJSONValue?

  public init(
    description: String? = nil,
    name: String,
    typeName: String?,
    isNullable: Bool = false,
    isSequence: Bool = false,
    constraints: NMOSJSONValue? = nil
  ) {
    self.description = description
    self.name = name
    self.typeName = typeName
    self.isNullable = isNullable
    self.isSequence = isSequence
    self.constraints = constraints
  }

  public var json: NMOSJSONValue {
    [
      "description": description.json, "name": .string(name), "typeName": typeName.json,
      "isNullable": .bool(isNullable), "isSequence": .bool(isSequence),
      "constraints": constraints ?? .null,
    ]
  }
}

/// MS-05-02 `NcFieldDescriptor`, which has the fields of a parameter's descriptor.
public typealias NcFieldDescriptor = NcParameterDescriptor

/// MS-05-02 `NcMethodDescriptor`.
public struct NcMethodDescriptor: Sendable, Hashable, NcJSONRepresentable {
  public var description: String?
  public var id: NcElementID
  public var name: String
  public var resultDatatype: String
  public var parameters: [NcParameterDescriptor]
  public var isDeprecated: Bool

  public init(
    description: String? = nil,
    id: NcElementID,
    name: String,
    resultDatatype: String,
    parameters: [NcParameterDescriptor] = [],
    isDeprecated: Bool = false
  ) {
    self.description = description
    self.id = id
    self.name = name
    self.resultDatatype = resultDatatype
    self.parameters = parameters
    self.isDeprecated = isDeprecated
  }

  public var json: NMOSJSONValue {
    [
      "description": description.json, "id": id.json, "name": .string(name),
      "resultDatatype": .string(resultDatatype), "parameters": .array(parameters.map(\.json)),
      "isDeprecated": .bool(isDeprecated),
    ]
  }
}

/// MS-05-02 `NcEventDescriptor`.
public struct NcEventDescriptor: Sendable, Hashable, NcJSONRepresentable {
  public var description: String?
  public var id: NcElementID
  public var name: String
  public var eventDatatype: String
  public var isDeprecated: Bool

  public init(
    description: String? = nil,
    id: NcElementID,
    name: String,
    eventDatatype: String,
    isDeprecated: Bool = false
  ) {
    self.description = description
    self.id = id
    self.name = name
    self.eventDatatype = eventDatatype
    self.isDeprecated = isDeprecated
  }

  public var json: NMOSJSONValue {
    [
      "description": description.json, "id": id.json, "name": .string(name),
      "eventDatatype": .string(eventDatatype), "isDeprecated": .bool(isDeprecated),
    ]
  }
}

/// MS-05-02 `NcClassDescriptor`: what a class itself defines, without what it inherits.
public struct NcClassDescriptor: Sendable, Hashable, NcJSONRepresentable {
  public var description: String?
  public var classID: NcClassID
  public var name: String
  /// The role every instance has, which only managers are given.
  public var fixedRole: String?
  public var properties: [NcPropertyDescriptor]
  public var methods: [NcMethodDescriptor]
  public var events: [NcEventDescriptor]

  public init(
    description: String? = nil,
    classID: NcClassID,
    name: String,
    fixedRole: String? = nil,
    properties: [NcPropertyDescriptor] = [],
    methods: [NcMethodDescriptor] = [],
    events: [NcEventDescriptor] = []
  ) {
    self.description = description
    self.classID = classID
    self.name = name
    self.fixedRole = fixedRole
    self.properties = properties
    self.methods = methods
    self.events = events
  }

  public var json: NMOSJSONValue {
    [
      "description": description.json, "classId": classID.json, "name": .string(name),
      "fixedRole": fixedRole.json, "properties": .array(properties.map(\.json)),
      "methods": .array(methods.map(\.json)), "events": .array(events.map(\.json)),
    ]
  }
}

/// MS-05-02 `NcEnumItemDescriptor`.
public struct NcEnumItemDescriptor: Sendable, Hashable, NcJSONRepresentable {
  public var description: String?
  public var name: String
  public var value: UInt16

  public init(description: String? = nil, name: String, value: UInt16) {
    self.description = description
    self.name = name
    self.value = value
  }

  public var json: NMOSJSONValue {
    ["description": description.json, "name": .string(name), "value": .integer(Int64(value))]
  }
}

/// MS-05-02 `NcDatatypeDescriptor` and the four descriptors derived from it.
public struct NcDatatypeDescriptor: Sendable, Hashable, NcJSONRepresentable {
  /// What kind of datatype it is, with what only that kind of descriptor carries.
  public enum Kind: Sendable, Hashable {
    case primitive
    /// Another name for `parentType`, or for a sequence of it.
    case typedef(parentType: String, isSequence: Bool)
    /// The fields the struct itself defines; `parentType` is the struct it extends.
    case `struct`(fields: [NcFieldDescriptor], parentType: String?)
    case `enum`(items: [NcEnumItemDescriptor])

    /// MS-05-02 `NcDatatypeType`.
    var type: Int64 {
      switch self {
      case .primitive: 0
      case .typedef: 1
      case .struct: 2
      case .enum: 3
      }
    }
  }

  public var description: String?
  public var name: String
  public var kind: Kind
  public var constraints: NMOSJSONValue?

  public init(description: String? = nil, name: String, kind: Kind, constraints: NMOSJSONValue? = nil) {
    self.description = description
    self.name = name
    self.kind = kind
    self.constraints = constraints
  }

  public var json: NMOSJSONValue {
    var object: [String: NMOSJSONValue] = [
      "description": description.json, "name": .string(name), "type": .integer(kind.type),
      "constraints": constraints ?? .null,
    ]
    switch kind {
    case .primitive:
      break
    case let .typedef(parentType, isSequence):
      object["parentType"] = .string(parentType)
      object["isSequence"] = .bool(isSequence)
    case let .struct(fields, parentType):
      object["fields"] = .array(fields.map(\.json))
      object["parentType"] = parentType.json
    case let .enum(items):
      object["items"] = .array(items.map(\.json))
    }
    return .object(object)
  }
}

/// MS-05-02 `NcBlockMemberDescriptor`.
public struct NcBlockMemberDescriptor: Sendable, Hashable, NcJSONRepresentable {
  public var description: String?
  public var role: String
  public var oid: NcOid
  public var constantOid: Bool
  public var classID: NcClassID
  public var userLabel: String?
  /// The block that contains the member.
  public var owner: NcOid

  public init(
    description: String? = nil,
    role: String,
    oid: NcOid,
    constantOid: Bool,
    classID: NcClassID,
    userLabel: String?,
    owner: NcOid
  ) {
    self.description = description
    self.role = role
    self.oid = oid
    self.constantOid = constantOid
    self.classID = classID
    self.userLabel = userLabel
    self.owner = owner
  }

  public var json: NMOSJSONValue {
    [
      "description": description.json, "role": .string(role), "oid": .integer(Int64(oid)),
      "constantOid": .bool(constantOid), "classId": classID.json, "userLabel": userLabel.json,
      "owner": .integer(Int64(owner)),
    ]
  }
}

/// MS-05-02 `NcTouchpointNmos`: the IS-04 resource an object stands for.
public struct NcTouchpoint: Sendable, Hashable, NcJSONRepresentable {
  /// The resource type, as IS-04 names it: `node`, `device`, `sender`, `receiver`...
  public var resourceType: String
  public var id: NMOSID

  public init(resourceType: String, id: NMOSID) {
    self.resourceType = resourceType
    self.id = id
  }

  public var json: NMOSJSONValue {
    [
      "contextNamespace": "x-nmos",
      "resource": ["resourceType": .string(resourceType), "id": .string(id.description)],
    ]
  }
}

/// MS-05-02 `NcPropertyChangeType`.
public enum NcPropertyChangeType: Int64, Sendable {
  case valueChanged = 0
  case sequenceItemAdded = 1
  case sequenceItemChanged = 2
  case sequenceItemRemoved = 3
}

/// MS-05-02 `NcPropertyConstraintsNumber`: the range the value of a numeric property is
/// held to. A bound that is nil is not constrained.
public struct NcPropertyConstraintsNumber: Sendable, Hashable, NcJSONRepresentable {
  public var propertyID: NcElementID
  public var defaultValue: NMOSJSONValue?
  public var minimum: NMOSJSONValue?
  public var maximum: NMOSJSONValue?
  public var step: NMOSJSONValue?

  public init(
    propertyID: NcElementID,
    defaultValue: NMOSJSONValue? = nil,
    minimum: NMOSJSONValue? = nil,
    maximum: NMOSJSONValue? = nil,
    step: NMOSJSONValue? = nil
  ) {
    self.propertyID = propertyID
    self.defaultValue = defaultValue
    self.minimum = minimum
    self.maximum = maximum
    self.step = step
  }

  public var json: NMOSJSONValue {
    [
      "propertyId": propertyID.json, "defaultValue": defaultValue ?? .null,
      "minimum": minimum ?? .null, "maximum": maximum ?? .null, "step": step ?? .null,
    ]
  }
}

/// MS-05-02 `NcPropertyChangedEventData`, the data of the `PropertyChanged` event.
public struct NcPropertyChangedEventData: Sendable, Hashable, NcJSONRepresentable {
  public var propertyID: NcElementID
  public var changeType: NcPropertyChangeType
  public var value: NMOSJSONValue
  public var sequenceItemIndex: UInt32?

  public init(
    propertyID: NcElementID,
    changeType: NcPropertyChangeType = .valueChanged,
    value: NMOSJSONValue,
    sequenceItemIndex: UInt32? = nil
  ) {
    self.propertyID = propertyID
    self.changeType = changeType
    self.value = value
    self.sequenceItemIndex = sequenceItemIndex
  }

  public var json: NMOSJSONValue {
    [
      "propertyId": propertyID.json, "changeType": .integer(changeType.rawValue), "value": value,
      "sequenceItemIndex": sequenceItemIndex.map { .integer(Int64($0)) } ?? .null,
    ]
  }
}
