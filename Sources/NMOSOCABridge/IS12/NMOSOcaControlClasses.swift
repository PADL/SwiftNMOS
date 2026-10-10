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
    /// An OCA property, read and written through its accessor methods; one of a standard
    /// property may be presented as an Nc datatype of its type's own.
    case property(OcaDevicePropertyDescriptor, NMOSOcaSchema?, (any NMOSOcaNcValue.Type)? = nil)
    /// One component of an OCA vector property, by the name of its field in the pair
    /// the property's accessors carry.
    case component(OcaDevicePropertyDescriptor, field: String, NMOSOcaSchema)
  }

  let value: Value
  let isReadOnly: Bool

  var description: OcaDevicePropertyDescriptor {
    switch value {
    case let .property(property, _, _), let .component(property, _, _): property
    }
  }

  /// A hidden property is served by its ID, but not described, notified or constrained.
  var isHidden: Bool { description.flags.contains(.hidden) }
}

/// How one method of an MS-05-02 class is invoked on an OCA object: the OCA method, and
/// the names and schemas of its parameters and results as OCP.2 carries them, which are
/// the names IS-12 arguments and the result's fields go by.
struct NMOSOcaMethodBinding: Sendable {
  struct Field: Sendable {
    let name: String
    let schema: NMOSOcaSchema
  }

  let methodID: OcaMethodID
  let parameters: [Field]
  let results: [Field]
}

/// An OCA class as the bridge presents it: its MS-05-02 class, how each property and
/// method below `NcObject` is served, and the non-standard classes its lineage contributes.
struct NMOSOcaControlClass: Sendable {
  let classID: NcClassID
  let properties: [NcElementID: NMOSOcaPropertyBinding]
  /// The methods of the non-standard classes; the standard ones are the object model's.
  let methods: [NcElementID: NMOSOcaMethodBinding]
  /// The MS-05-02 ID each OCA property is presented under, the user label included.
  let standardIDs: [OcaPropertyID: NcElementID]
  /// The OCA property that holds the object's user label, if it has one a controller can set.
  let label: OcaDevicePropertyDescriptor?
  let descriptors: [NcClassDescriptor]
}

extension SwiftOCADevice.OcaRoot {
  /// The object's OCA role as MS-05-02 allows one: without dots, as they separate role paths.
  var ncRole: String { role.replacingOccurrences(of: ".", with: "_") }
}

/// Works out, once per OCA class, how it is presented. The classes and datatypes a
/// class manager publishes are those of the classes met so far.
@OcaDevice
final class NMOSOcaControlClasses {
  let datatypes = NMOSOcaDatatypes()
  private let logger: Logger
  private var classes = [ObjectIdentifier: NMOSOcaControlClass]()
  /// Every non-standard class of the objects met so far, each once, made again when a
  /// class not met before is described.
  private(set) var descriptors = [NcClassDescriptor]()
  /// The datatypes those descriptors refer to, and those they refer to in turn.
  private(set) var datatypeDescriptors = [NcDatatypeDescriptor]()

  nonisolated init(logger: Logger) {
    self.logger = logger
  }

  /// Each class once: where descriptors share a class ID, as a class named only by another's
  /// ID does with its own descriptor, the one with the most elements.
  private func listDescriptors() -> [NcClassDescriptor] {
    let byClass = Dictionary(classes.values.flatMap(\.descriptors).map { ($0.classID, $0) }) { first, second in
      first.properties.count + first.methods.count >= second.properties.count + second.methods.count ? first : second
    }
    return byClass.values.sorted { $0.classID.lexicographicallyPrecedes($1.classID) }
  }

  /// The datatypes met so far that a described class refers to; one met only by a hidden
  /// element, or by one that could not be presented, is left out.
  private func listDatatypes() -> [NcDatatypeDescriptor] {
    let met = Dictionary(datatypes.descriptors.map { ($0.name, $0) }) { first, _ in first }
    var pending = descriptors.flatMap { descriptor in
      descriptor.properties.compactMap(\.typeName) + descriptor.events.map(\.eventDatatype)
        + descriptor.methods.flatMap { [$0.resultDatatype] + $0.parameters.compactMap(\.typeName) }
    }
    var referred = Set<String>()
    while let name = pending.popLast() {
      guard referred.insert(name).inserted, let datatype = met[name] else { continue }
      switch datatype.kind {
      case let .typedef(parentType, _):
        pending.append(parentType)
      case let .struct(fields, parentType):
        pending += fields.compactMap(\.typeName) + [parentType].compactMap(\.self)
      case .primitive, .enum:
        break
      }
    }
    return datatypes.descriptors.filter { referred.contains($0.name) }
  }

  func controlClass(of object: SwiftOCADevice.OcaRoot) -> NMOSOcaControlClass {
    let type = ObjectIdentifier(type(of: object))
    if let known = classes[type] { return known }
    let controlClass = describe(object)
    classes[type] = controlClass
    descriptors = listDescriptors()
    datatypeDescriptors = listDatatypes()
    return controlClass
  }

  /// How the elements of a class are served: of one OCA class, or gathered over a lineage.
  private struct Bindings {
    var properties = [NcElementID: NMOSOcaPropertyBinding]()
    var methods = [NcElementID: NMOSOcaMethodBinding]()
    var standardIDs = [OcaPropertyID: NcElementID]()
    /// The OCA properties already served as standard ones, or by where an object is found.
    var consumed = Set<OcaPropertyID>()

    mutating func merge(_ other: Bindings) {
      properties.merge(other.properties) { _, new in new }
      methods.merge(other.methods) { _, new in new }
      standardIDs.merge(other.standardIDs) { _, new in new }
    }
  }

  private typealias Anchored = (depth: Int, anchor: NMOSOcaControlMapping.Anchor)

  private func describe(_ object: SwiftOCADevice.OcaRoot) -> NMOSOcaControlClass {
    let lineage = object.deviceClassDescriptors
    let anchored = anchors(in: lineage)
    guard let (anchorDepth, anchor) = anchored.max(by: { $0.depth < $1.depth }) else {
      // OcaRoot is always in the lineage, so nothing gets here
      return NMOSOcaControlClass(
        classID: NcStandardModel.object, properties: [:], methods: [:], standardIDs: [:], label: nil, descriptors: []
      )
    }
    let declared = Dictionary(
      lineage.flatMap(\.properties).map { ($0.propertyID, $0) }, uniquingKeysWith: { first, _ in first }
    )

    var bindings = Bindings()
    presentStandardProperties(of: anchored.map(\.anchor), under: anchor, declared, into: &bindings)
    let label = userLabel(in: declared)
    if let label {
      bindings.consumed.insert(label.propertyID)
      bindings.standardIDs[label.propertyID] = .userLabel
    }
    // NcObject states an object's owner from where it is found, not from what it says
    bindings.consumed.formUnion(declared.values.filter { $0.flags.contains(.owner) }.map(\.propertyID))

    // what the OCA classes have beyond that, one non-standard class per OCA class
    var descriptors = [NcClassDescriptor]()
    for (depth, ocaClass) in lineage.presented where !anchor.hideSubclasses || depth > anchorDepth {
      // a class ID names every class above it, and each is to be described, whether or
      // not a class of the object stands for it
      descriptors += ocaClass.classID.classIDs(after: lineage[depth - 1].classID).map { unstated in
        NcClassDescriptor(classID: anchor.nc + [NMOSOcaControlMapping.authorityKey] + unstated.ncIndices, name: unstated.className)
      }
      // a class's level is its depth by its ID, as OCA has it too
      let level = ocaClass.classID.ncLevel(under: anchor.nc)
      let (descriptor, described) = describe(
        ocaClass: ocaClass, at: level, under: anchor, consumed: bindings.consumed
      )
      bindings.merge(described)
      descriptors.append(descriptor)
    }
    return controlClass(anchor, descriptors, bindings, label: label, role: object.ncRole)
  }

  /// The classes of the lineage that have a standard counterpart, with their depth.
  private func anchors(in lineage: [OcaDeviceClassDescriptor]) -> [Anchored] {
    NMOSOcaControlMapping.anchors.compactMap { anchor in
      lineage.firstIndex { $0.classID == anchor.oca }.map { (depth: $0, anchor: anchor) }
    }
  }

  /// The standard properties, from every anchor the chosen one derives from.
  private func presentStandardProperties(
    of anchors: [NMOSOcaControlMapping.Anchor],
    under anchor: NMOSOcaControlMapping.Anchor,
    _ declared: [OcaPropertyID: OcaDevicePropertyDescriptor],
    into bindings: inout Bindings
  ) {
    // which standard properties are read only is the object model's to enforce
    for inherited in anchors where anchor.nc.starts(with: inherited.nc) {
      for property in inherited.properties {
        switch property.source {
        case let .members(id):
          // the object model lists the members; a change to them is still notified
          bindings.consumed.insert(id)
          bindings.standardIDs[id] = property.id
        case let .property(id):
          // an object without the OCA property does without the standard one
          guard let description = declared[id], description.getMethodID != nil else { continue }
          bindings.consumed.insert(id)
          bindings.standardIDs[id] = property.id
          let ncForm = description.valueType as? any NMOSOcaNcValue.Type
          bindings.properties[property.id] = NMOSOcaPropertyBinding(
            value: .property(description, try? datatypes.schema(of: description.valueType), ncForm),
            isReadOnly: !description.isSettable || ncForm != nil
          )
        }
      }
    }
  }

  /// The OCA property that holds the user label, if a controller can set it.
  private func userLabel(
    in declared: [OcaPropertyID: OcaDevicePropertyDescriptor]
  ) -> OcaDevicePropertyDescriptor? {
    declared.values.first { $0.flags.contains(.label) && $0.getMethodID != nil && $0.isSettable }
  }

  /// One OCA class's own elements, at `level`, as a non-standard class: its descriptor,
  /// and how the elements it presents are served.
  private func describe(
    ocaClass: OcaDeviceClassDescriptor,
    at level: UInt16,
    under anchor: NMOSOcaControlMapping.Anchor,
    consumed: Set<OcaPropertyID>
  ) -> (NcClassDescriptor, Bindings) {
    var descriptor = NcClassDescriptor(
      classID: anchor.nc + [NMOSOcaControlMapping.authorityKey] + ocaClass.classID.ncIndices,
      name: ocaClass.type.className
    )
    var described = Bindings()
    // (a vector is listed once, under the ID of its x component)
    for property in ocaClass.properties where !consumed.contains(property.propertyID) {
      present(property, at: level, in: &descriptor, into: &described)
    }
    presentMethods(of: ocaClass, at: level, under: anchor, in: &descriptor, into: &described)
    return (descriptor, described)
  }

  /// A property as one or, for a vector, two property descriptors and their bindings.
  private func present(
    _ property: OcaDevicePropertyDescriptor,
    at level: UInt16,
    in descriptor: inout NcClassDescriptor,
    into described: inout Bindings
  ) {
    let className = descriptor.name
    guard property.getMethodID != nil else {
      logger.trace("not presenting \(className).\(property.name): no getter")
      return
    }
    do {
      // a vector is two OCA properties with one pair of accessors, and its change
      // events are of one component each, so it is presented as its two components
      let components: [(name: String, id: OcaPropertyID, binding: NMOSOcaPropertyBinding.Value)]
      let schema: NMOSOcaSchema
      if let yPropertyID = property.yPropertyID, let componentType = property.componentType,
         let names = property.componentNames
      {
        schema = try datatypes.schema(of: componentType)
        components = [(names.x, property.propertyID, "x"), (names.y, yPropertyID, "y")].map { name, id, field in
          (name, id, .component(property, field: Ocp2Naming.wireName(field), schema))
        }
      } else {
        schema = try datatypes.schema(of: property.valueType)
        components = [(property.name, property.propertyID, .property(property, schema))]
      }
      // a hidden property is not described, so nothing is subscribed to or notified of it
      let reference = property.flags.contains(.hidden) ? nil : try datatypes.reference(to: schema)
      // a setter is no promise: the device may still refuse a set when it is made
      let isReadOnly = !property.isSettable
      for component in components {
        let id = NcElementID(level: level, index: component.id.propertyIndex)
        described.properties[id] = NMOSOcaPropertyBinding(value: component.binding, isReadOnly: isReadOnly)
        guard let reference else { continue }
        descriptor.properties.append(NcPropertyDescriptor(
          id: id, name: component.name, typeName: reference.typeName,
          isReadOnly: isReadOnly, isNullable: reference.isNullable,
          isSequence: reference.isSequence
        ))
        described.standardIDs[component.id] = id
      }
    } catch {
      logger.trace("not presenting \(className).\(property.name): \(error)")
    }
  }

  /// The class's table methods as method descriptors and their bindings. A property's
  /// accessors are served by Get and Set; a method that does not describe what it takes,
  /// or takes or returns what MS-05-02 cannot describe, is left out.
  private func presentMethods(
    of ocaClass: OcaDeviceClassDescriptor,
    at level: UInt16,
    under anchor: NMOSOcaControlMapping.Anchor,
    in descriptor: inout NcClassDescriptor,
    into described: inout Bindings
  ) {
    let className = descriptor.name
    for method in candidates(in: ocaClass) {
      let id = NcElementID(level: level, index: method.methodID.methodIndex)
      assert(
        !NcStandardModel.methodIDs(of: anchor.nc).contains(id),
        "\(className).\(method.name) would be presented as a standard method, \(id)"
      )
      do {
        let parameters = try method.parameters.map { try field($0) }
        let results = try method.results.map { try field($0) }
        let binding = NMOSOcaMethodBinding(methodID: method.methodID, parameters: parameters, results: results)
        // a hidden method can be invoked, but is not described
        guard !method.isHidden else {
          described.methods[id] = binding
          continue
        }
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
        described.methods[id] = binding
        let resultDatatype = try datatypes.methodResult(named: className + method.name + "Result", fields: fields)
        descriptor.methods.append(NcMethodDescriptor(
          id: id, name: method.name, resultDatatype: resultDatatype, parameters: descriptors, isDeprecated: false
        ))
      } catch {
        logger.trace("not presenting \(className).\(method.name): \(error)")
      }
    }
  }

  /// The methods of the class that are presented if their types can be described and the
  /// device lets the network call them, in index order. What the class itself declares
  /// decides which of its methods are presented, here and nowhere else.
  private func candidates(in ocaClass: OcaDeviceClassDescriptor) -> [OcaDeviceMethodDescriptor] {
    let accessors = Set(ocaClass.properties.flatMap { [$0.getMethodID, $0.setMethodID] }.compactMap(\.self))
    // a subclass that declares a method again is the one it is dispatched to
    let methods = Dictionary(ocaClass.methods.map { ($0.methodID, $0) }, uniquingKeysWith: { _, last in last })
    return methods.values.sorted { $0.methodID.methodIndex < $1.methodID.methodIndex }.filter { method in
      guard !accessors.contains(method.methodID) else { return false }
      return method.isDescribed
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
    _ bindings: Bindings,
    label: OcaDevicePropertyDescriptor?,
    role: String
  ) -> NMOSOcaControlClass {
    guard Self.isPresentedAsDerivedClass(under: anchor.nc, descriptors), var leaf = descriptors.last else {
      return NMOSOcaControlClass(
        classID: anchor.nc, properties: bindings.properties, methods: bindings.methods,
        standardIDs: bindings.standardIDs, label: label, descriptors: []
      )
    }
    var descriptors = descriptors
    if leaf.classID.starts(with: NcStandardModel.manager) {
      // a manager's role is fixed, and a class derived from a standard manager keeps its role
      leaf.fixedRole = NcStandardModel.fixedRole(of: anchor.nc) ?? role
      descriptors[descriptors.count - 1] = leaf
    }
    return NMOSOcaControlClass(
      classID: leaf.classID, properties: bindings.properties, methods: bindings.methods,
      standardIDs: bindings.standardIDs, label: label, descriptors: descriptors
    )
  }

  /// Whether a lineage is presented as a class derived from the standard one rather than as
  /// the standard class: one that adds a property or a method to it; or any manager, as
  /// NcManager is only a base and each manager is the one object of its class.
  private static func isPresentedAsDerivedClass(
    under anchor: NcClassID,
    _ descriptors: [NcClassDescriptor]
  ) -> Bool {
    anchor == NcStandardModel.manager || descriptors.contains { !$0.properties.isEmpty || !$0.methods.isEmpty }
  }
}
