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
import Logging
import NMOS
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// How one property of an MS-05-02 class is read and written on an OCA object.
struct NMOSOcaPropertyBinding: Sendable {
  enum Value: Sendable {
    case constant(NMOSJSONValue)
    /// An OCA property, read and written through its accessor methods.
    case property(OcaDevicePropertyDescriptor, NMOSOcaSchema?, NMOSOcaControlMapping.Transform)
    /// One component of an OCA vector property, by the name of its field in the pair
    /// the property's accessors carry.
    case component(OcaDevicePropertyDescriptor, field: String, NMOSOcaSchema)
  }

  var value: Value
  var isReadOnly: Bool
}

/// How one method of an MS-05-02 class is invoked on an OCA object: the OCA method, and
/// the names and schemas of its parameters and results as OCP.2 carries them, which are
/// the names IS-12 arguments and the result's fields go by.
struct NMOSOcaMethodBinding: Sendable {
  struct Field: Sendable {
    var name: String
    var schema: NMOSOcaSchema
  }

  var methodID: OcaMethodID
  var parameters: [Field]
  var results: [Field]
}

/// An OCA class as the bridge presents it: its MS-05-02 class, how each property and
/// method below `NcObject` is served, and the non-standard classes its lineage contributes.
struct NMOSOcaControlClass: Sendable {
  var classID: NcClassID
  var properties: [NcElementID: NMOSOcaPropertyBinding]
  /// The methods of the non-standard classes; the standard ones are the object model's.
  var methods: [NcElementID: NMOSOcaMethodBinding] = [:]
  /// The MS-05-02 ID each OCA property is presented under, the user label included.
  var standardIDs: [OcaPropertyID: NcElementID]
  /// The OCA property that holds the object's user label, if it has one a controller can set.
  var label: OcaDevicePropertyDescriptor?
  var descriptors: [NcClassDescriptor]
}

/// Works out, once per OCA class, how the mapping presents it. The classes and
/// datatypes a class manager publishes are those of the classes met so far.
@OcaDevice
final class NMOSOcaControlClasses {
  let mapping: NMOSOcaControlMapping
  let datatypes = NMOSOcaDatatypes()
  private let logger: Logger
  private var classes = [ObjectIdentifier: NMOSOcaControlClass]()
  /// Every non-standard class of the objects met so far, each once, made again when a
  /// class not met before is described.
  private(set) var descriptors = [NcClassDescriptor]()

  nonisolated init(mapping: NMOSOcaControlMapping, logger: Logger) {
    self.mapping = mapping
    self.logger = logger
  }

  private func listDescriptors() -> [NcClassDescriptor] {
    var seen = Set<NcClassID>()
    return classes.values.flatMap(\.descriptors).filter { seen.insert($0.classID).inserted }
      .sorted { $0.classID.lexicographicallyPrecedes($1.classID) }
  }

  func controlClass(
    of object: SwiftOCADevice.OcaRoot,
    role: String
  ) -> NMOSOcaControlClass {
    let type = ObjectIdentifier(type(of: object))
    if let known = classes[type] { return known }
    let controlClass = describe(object, role: role)
    classes[type] = controlClass
    descriptors = listDescriptors()
    return controlClass
  }

  /// How the elements of an object's class are served, gathered over its lineage.
  private struct Presentation {
    var properties = [NcElementID: NMOSOcaPropertyBinding]()
    var methods = [NcElementID: NMOSOcaMethodBinding]()
    var standardIDs = [OcaPropertyID: NcElementID]()
    /// The OCA properties already served as standard ones, or by where an object is found.
    var consumed = Set<OcaPropertyID>()
  }

  /// One OCA class of a lineage as a non-standard class: its descriptor, and how the
  /// elements it presents are served.
  private struct ClassPresentation {
    var descriptor: NcClassDescriptor
    var properties = [NcElementID: NMOSOcaPropertyBinding]()
    var methods = [NcElementID: NMOSOcaMethodBinding]()
    var standardIDs = [OcaPropertyID: NcElementID]()
  }

  private typealias Anchored = (depth: Int, anchor: NMOSOcaControlMapping.Anchor)

  private func describe(
    _ object: SwiftOCADevice.OcaRoot,
    role: String
  ) -> NMOSOcaControlClass {
    let lineage = object.deviceClassDescriptors
    let anchored = anchors(in: lineage)
    guard let anchor = anchored.max(by: { $0.depth < $1.depth })?.anchor else {
      // OcaRoot is always in the lineage, so only a mapping without it gets here
      return NMOSOcaControlClass(classID: NcStandardModel.object, properties: [:], standardIDs: [:], descriptors: [])
    }
    let declared = Dictionary(
      lineage.flatMap(\.properties).map { ($0.propertyID, $0) }, uniquingKeysWith: { first, _ in first }
    )

    var presentation = Presentation()
    presentStandardProperties(of: anchored.map(\.anchor), under: anchor, declared, into: &presentation)
    let label = userLabel(in: declared)
    if let label {
      presentation.consumed.insert(label.propertyID)
      presentation.standardIDs[label.propertyID] = .userLabel
    }
    // NcObject states an object's owner from where it is found, not from what it says
    presentation.consumed.formUnion(declared.values.filter { $0.name == mapping.ownerProperty }.map(\.propertyID))

    // what the OCA classes have beyond that, one non-standard class per OCA class
    var descriptors = [NcClassDescriptor]()
    for (depth, ocaClass) in Self.presented(lineage) {
      // a class ID names every class above it, and each is to be described, whether or
      // not a class of the object stands for it
      for unstated in Self.classIDs(from: lineage[depth - 1].classID, to: ocaClass.classID) {
        descriptors.append(NcClassDescriptor(
          classID: anchor.nc + [mapping.authorityKey] + Self.fields(below: unstated),
          name: Self.name(of: unstated)
        ))
      }
      // a class's level is its depth by its ID, as OCA has it too
      let level = Self.level(of: ocaClass.classID, under: anchor.nc)
      let described = describe(
        ocaClass: ocaClass, at: level, under: anchor, consumed: presentation.consumed
      )
      presentation.properties.merge(described.properties) { _, new in new }
      presentation.methods.merge(described.methods) { _, new in new }
      presentation.standardIDs.merge(described.standardIDs) { _, new in new }
      descriptors.append(described.descriptor)
    }
    return controlClass(anchor, descriptors, presentation, label: label, role: role)
  }

  /// The classes of the lineage that have a standard counterpart, with their depth.
  private func anchors(in lineage: [OcaDeviceClassDescriptor]) -> [Anchored] {
    mapping.anchors.compactMap { anchor in
      lineage.firstIndex { $0.classID == anchor.oca }.map { (depth: $0, anchor: anchor) }
    }
  }

  /// The standard properties, from every anchor the chosen one derives from.
  private func presentStandardProperties(
    of anchors: [NMOSOcaControlMapping.Anchor],
    under anchor: NMOSOcaControlMapping.Anchor,
    _ declared: [OcaPropertyID: OcaDevicePropertyDescriptor],
    into presentation: inout Presentation
  ) {
    for inherited in anchors where anchor.nc.starts(with: inherited.nc) {
      let standard = NcStandardModel.classDescriptor(inherited.nc)
      for property in inherited.properties {
        let isReadOnly = standard?.properties.first { $0.id == property.id }?.isReadOnly ?? true
        switch property.source {
        case let .constant(value):
          presentation.properties[property.id] = .init(value: .constant(value), isReadOnly: true)
        case let .members(id):
          presentation.consumed.insert(id)
        case let .property(id, transform):
          // an object without the OCA property does without the standard one
          guard let description = declared[id], description.getMethodID != nil else { continue }
          presentation.consumed.insert(id)
          presentation.standardIDs[id] = property.id
          presentation.properties[property.id] = NMOSOcaPropertyBinding(
            value: .property(description, try? datatypes.schema(of: description.valueType), transform),
            isReadOnly: isReadOnly || !description.isSettable || !transform.isWritable
          )
        }
      }
    }
  }

  /// The OCA property that holds the user label, if a controller can set it.
  private func userLabel(
    in declared: [OcaPropertyID: OcaDevicePropertyDescriptor]
  ) -> OcaDevicePropertyDescriptor? {
    declared.values.first {
      $0.name == mapping.userLabelProperty && $0.valueType == String.self
        && $0.getMethodID != nil && $0.isSettable
    }
  }

  /// One OCA class's own elements, at `level`, as a non-standard class.
  private func describe(
    ocaClass: OcaDeviceClassDescriptor,
    at level: UInt16,
    under anchor: NMOSOcaControlMapping.Anchor,
    consumed: Set<OcaPropertyID>
  ) -> ClassPresentation {
    var described = ClassPresentation(descriptor: NcClassDescriptor(
      classID: anchor.nc + [mapping.authorityKey] + Self.fields(below: ocaClass.classID),
      name: Self.name(of: ocaClass.type)
    ))
    // (a vector is listed once, under the ID of its x component)
    for property in ocaClass.properties where !consumed.contains(property.propertyID) {
      present(property, of: ocaClass, at: level, into: &described)
    }
    presentMethods(of: ocaClass, at: level, under: anchor, into: &described)
    return described
  }

  /// A property as one or, for a vector, two property descriptors and their bindings.
  private func present(
    _ property: OcaDevicePropertyDescriptor,
    of ocaClass: OcaDeviceClassDescriptor,
    at level: UInt16,
    into described: inout ClassPresentation
  ) {
    let className = described.descriptor.name
    guard property.getMethodID != nil else {
      logger.trace("\(className).\(property.name) has no getter, so it is not presented")
      return
    }
    do {
      // a vector is two OCA properties with one pair of accessors, and its change
      // events are of one component each, so it is presented as its two components
      let components: [(name: String, id: OcaPropertyID, binding: NMOSOcaPropertyBinding.Value)]
      let schema: NMOSOcaSchema
      if let yPropertyID = property.yPropertyID, let componentType = property.componentType {
        schema = try datatypes.schema(of: componentType)
        let stem = property.name.hasSuffix("XY") ? String(property.name.dropLast(2)) : property.name
        components = [("X", property.propertyID), ("Y", yPropertyID)].map { axis, id in
          (stem + axis, id, .component(property, field: Ocp2Encoder.fieldName(axis.lowercased()), schema))
        }
      } else {
        schema = try datatypes.schema(of: property.valueType)
        components = [(property.name, property.propertyID, .property(property, schema, .identity))]
      }
      let reference = try datatypes.reference(to: schema)
      // a setter is no promise: the device may still refuse a set when it is made
      let isReadOnly = !property.isSettable
      for component in components {
        let id = NcElementID(level: level, index: component.id.propertyIndex)
        let binding = NMOSOcaPropertyBinding(value: component.binding, isReadOnly: isReadOnly)
        described.descriptor.properties.append(NcPropertyDescriptor(
          id: id, name: component.name, typeName: reference.typeName,
          isReadOnly: isReadOnly, isNullable: reference.isNullable,
          isSequence: reference.isSequence
        ))
        described.properties[id] = binding
        described.standardIDs[component.id] = id
      }
    } catch {
      logger.trace("\(className).\(property.name) is not presented: \(error)")
    }
  }

  /// The class's table methods as method descriptors and their bindings. A property's
  /// accessors are served by Get and Set; a method that does not describe what it takes,
  /// or takes or returns what MS-05-02 cannot describe, is left out.
  private func presentMethods(
    of ocaClass: OcaDeviceClassDescriptor,
    at level: UInt16,
    under anchor: NMOSOcaControlMapping.Anchor,
    into described: inout ClassPresentation
  ) {
    let className = described.descriptor.name
    for method in candidates(in: ocaClass, named: className) {
      let id = NcElementID(level: level, index: method.methodID.methodIndex)
      assert(
        !Self.standardMethods(under: anchor.nc).contains(id),
        "\(className).\(method.name) would be presented as a standard method, \(id)"
      )
      do {
        let parameters = try method.parameters.map { try field($0) }
        let results = try method.results.map { try field($0) }
        // one result is the `value` of an NcMethodResult, as a property's is; several are
        // fields of their own
        let fields = results.count == 1
          ? [(name: "value", schema: results[0].schema)] : results.map { ($0.name, $0.schema) }
        let descriptors = try parameters.map { parameter in
          let reference = try datatypes.reference(to: parameter.schema)
          return NcParameterDescriptor(
            name: parameter.name, typeName: reference.typeName,
            isNullable: reference.isNullable, isSequence: reference.isSequence
          )
        }
        described.methods[id] = NMOSOcaMethodBinding(
          methodID: method.methodID, parameters: parameters, results: results
        )
        let resultDatatype = try datatypes.methodResult(named: className + method.name + "Result", fields: fields)
        described.descriptor.methods.append(NcMethodDescriptor(
          id: id, name: method.name, resultDatatype: resultDatatype, parameters: descriptors, isDeprecated: false
        ))
      } catch {
        logger.trace("\(className).\(method.name) is not presented: \(error)")
      }
    }
  }

  /// The methods of the class that are presented if their types can be described and the
  /// device lets the network call them, in index order. What the class itself declares
  /// decides which of its methods are presented, here and nowhere else.
  private func candidates(
    in ocaClass: OcaDeviceClassDescriptor,
    named className: String
  ) -> [OcaDeviceMethodDescriptor] {
    let accessors = Set(ocaClass.properties.flatMap { [$0.getMethodID, $0.setMethodID] }.compactMap(\.self))
    // a subclass that declares a method again is the one it is dispatched to
    var methods = [OcaMethodID: OcaDeviceMethodDescriptor]()
    for method in ocaClass.methods { methods[method.methodID] = method }
    return methods.values.sorted { $0.methodID.methodIndex < $1.methodID.methodIndex }.filter { method in
      guard !accessors.contains(method.methodID) else { return false }
      guard method.isDescribed else {
        logger.trace("\(className).\(method.name) does not describe its parameters, so it is not presented")
        return false
      }
      return true
    }
  }

  private func field(_ parameter: OcaParameterDescriptor) throws -> NMOSOcaMethodBinding.Field {
    try NMOSOcaMethodBinding.Field(name: parameter.name, schema: datatypes.schema(of: parameter.type))
  }

  /// The class the object is presented as: the standard class, unless the lineage adds
  /// something of its own to it.
  private func controlClass(
    _ anchor: NMOSOcaControlMapping.Anchor,
    _ descriptors: [NcClassDescriptor],
    _ presentation: Presentation,
    label: OcaDevicePropertyDescriptor?,
    role: String
  ) -> NMOSOcaControlClass {
    guard Self.isClassOfItsOwn(under: anchor.nc, descriptors), var leaf = descriptors.last else {
      return NMOSOcaControlClass(
        classID: anchor.nc, properties: presentation.properties, methods: presentation.methods,
        standardIDs: presentation.standardIDs, label: label, descriptors: []
      )
    }
    var descriptors = descriptors
    if leaf.classID.starts(with: NcStandardModel.manager) {
      // a manager's role is fixed, and a class derived from a standard manager keeps its role
      leaf.fixedRole = NcStandardModel.fixedRole(of: anchor.nc) ?? role
      descriptors[descriptors.count - 1] = leaf
    }
    return NMOSOcaControlClass(
      classID: leaf.classID, properties: presentation.properties, methods: presentation.methods,
      standardIDs: presentation.standardIDs, label: label, descriptors: descriptors
    )
  }

  /// The classes of a lineage whose elements, properties and methods alike, are presented:
  /// all but OcaRoot. NcObject owns level 1, so OcaRoot's elements would take the IDs of
  /// NcObject's (and, under a deeper anchor, the anchor's own); they are served by NcObject.
  static func presented(
    _ lineage: [OcaDeviceClassDescriptor]
  ) -> some Sequence<(offset: Int, element: OcaDeviceClassDescriptor)> {
    lineage.enumerated().dropFirst()
  }

  /// MS-05-02's own methods of a standard class and of the standard classes above it,
  /// which the object model answers before the bridge is asked.
  static func standardMethods(under anchor: NcClassID) -> Set<NcElementID> {
    let lineage = anchor.indices.compactMap { NcStandardModel.classDescriptor(Array(anchor[...$0])) }
    return Set(lineage.flatMap(\.methods).map(\.id))
  }

  /// The MS-05-02 level an OCA class's elements are presented at under an anchor:
  /// N + L − 1, N being the anchor's level and L the class's OCA level.
  static func level(of classID: OcaClassID, under anchor: NcClassID) -> UInt16 {
    anchor.ncLevel + fields(below: classID).ncLevel
  }

  /// Whether a lineage is presented as a class of its own: one that adds a property or a
  /// method to the standard class; or any manager, as NcManager is only a base and each
  /// manager is the one object of its class.
  static func isClassOfItsOwn(under anchor: NcClassID, _ descriptors: [NcClassDescriptor]) -> Bool {
    anchor == NcStandardModel.manager || descriptors.contains { !$0.properties.isEmpty || !$0.methods.isEmpty }
  }

  /// The OCA class ID's fields after the leading 1, as MS-05-02 class indices. OCA's
  /// proprietary marker and the two fields of its authority become that authority's key.
  static func fields(below classID: OcaClassID) -> NcClassID {
    let fields = classID.fields.map { Int32($0) }.dropFirst()
    var indices = NcClassID()
    var index = fields.startIndex
    while index < fields.endIndex {
      if fields[index] == 0xFFFF, index + 2 < fields.endIndex {
        indices.append(-((fields[index + 1] & 0xFF) << 16 | fields[index + 2]))
        index += 3
      } else {
        indices.append(fields[index])
        index += 1
      }
    }
    return indices
  }

  /// The classes `classID` names between itself and `ancestor`, nearest the ancestor first.
  static func classIDs(from ancestor: OcaClassID, to classID: OcaClassID) -> [OcaClassID] {
    var between = [OcaClassID]()
    var parent = classID.parent
    while let id = parent, id != ancestor, id.isSubclass(of: ancestor) {
      between.insert(id, at: 0)
      parent = id.parent
    }
    return between
  }

  /// The name of a class known only by its ID: the registered class of that ID, if any.
  private static func name(of classID: OcaClassID) -> String {
    if let type = try? OcaDeviceClassRegistry.shared.match(classID: classID), type.classID == classID {
      return name(of: type)
    }
    return "OcaClass" + classID.fields.map { String($0) }.joined(separator: "_")
  }

  /// The class's name without its generic arguments; `Nc` is the standard's to use.
  private static func name(of type: SwiftOCADevice.OcaRoot.Type) -> String {
    let name = String(String(describing: type).prefix { $0 != "<" })
    return name.hasPrefix("Nc") ? "Oca" + name : name
  }
}
