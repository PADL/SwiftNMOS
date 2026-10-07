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

/// An object of an `NcObjectModel`, as MS-05-02's classes have it. Each class answers
/// its own methods and properties and passes the rest to the class it derives from, as
/// SwiftOCA's classes do; what no standard class has is the source's.
class NcObject<Source: NcObjectSource> {
  let identity: Source.Identity
  let model: NcObjectModel<Source>

  var source: Source { model.source }

  init(_ identity: Source.Identity, model: NcObjectModel<Source>) {
    self.identity = identity
    self.model = model
  }

  func handleCommand(_ command: NcCommand, _ arguments: NcArguments, _ session: NcSession) async throws -> NcMethodResult {
    switch (command.methodID.level, command.methodID.index) {
    case (1, 1): try await get(arguments.propertyID(), session)
    case (1, 2): try await set(arguments.propertyID(), to: arguments.value(), session)
    case (1, 3...7): try await sequence(command.methodID.index, arguments, session)
    default: await source.handleCommand(command, on: identity, session: session)
    }
  }

  func get(_ property: NcElementID, _ session: NcSession) async -> NcMethodResult {
    switch (property.level, property.index) {
    case (1, 1): return NcMethodResult(value: identity.classID.json)
    case (1, 2): return NcMethodResult(value: .integer(Int64(identity.oid)))
    case (1, 3): return NcMethodResult(value: .bool(identity.constantOid))
    case (1, 4): return NcMethodResult(value: identity.owner.map { .integer(Int64($0)) } ?? .null)
    case (1, 5): return NcMethodResult(value: .string(identity.role))
    case (1, 7): return await NcMethodResult(value: source.touchpoints(of: identity).map { .array($0.map(\.json)) } ?? .null)
    case (1, 8):
      let constraints = await source.runtimeConstraints(of: identity, session: session)
      return NcMethodResult(value: constraints.isEmpty ? .null : .array(constraints))
    case (1, 6): break
    case (1, _): return Self.noProperty(property)
    default: break
    }
    // the user label, and whatever the classes derived from NcObject have
    return await source.get(property, of: identity, session: session)
  }

  func set(_ property: NcElementID, to value: NMOSJSONValue, _ session: NcSession) async -> NcMethodResult {
    switch (property.level, property.index) {
    case (1, 6): break
    case (1, 1...8): return Self.readOnly(property)
    case (1, _): return Self.noProperty(property)
    default: break
    }
    // a property MS-05-02 declares read only is read only, whatever the source has
    if Self.standardProperty(property, of: identity.classID)?.isReadOnly == true { return Self.readOnly(property) }
    return await source.set(property, of: identity, to: value, session: session)
  }

  /// The descriptor of a property a standard class in the lineage declares.
  private static func standardProperty(_ property: NcElementID, of classID: NcClassID) -> NcPropertyDescriptor? {
    classID.indices.lazy.compactMap { NcStandardModel.classDescriptor(Array(classID[...$0])) }
      .compactMap { $0.properties.first { $0.id == property } }.first
  }

  /// The sequence methods, 1m3 to 1m7, in terms of reading and writing the whole value.
  private func sequence(
    _ method: UInt16,
    _ arguments: NcArguments,
    _ session: NcSession
  ) async throws -> NcMethodResult {
    let property = try arguments.propertyID()
    // a change is a read and then a write, which two sessions must not interleave
    guard (4...6).contains(method) else { return try await sequence(method, of: property, arguments, session) }
    let key = NcSequenceLocks.Key(oid: identity.oid, property: property)
    let locks = model.sequenceLocks
    await locks.acquire(key)
    defer { locks.release(key) }
    return try await sequence(method, of: property, arguments, session)
  }

  private func sequence(
    _ method: UInt16,
    of property: NcElementID,
    _ arguments: NcArguments,
    _ session: NcSession
  ) async throws -> NcMethodResult {
    let current = await get(property, session)
    guard !current.status.isError else { return current }
    // a null is a sequence's only where the property is declared one
    guard let value = current.value else { return Self.notASequence(property) }
    if value.arrayValue == nil {
      guard value.isNull, await isSequence(property) else { return Self.notASequence(property) }
    }
    var items = value.arrayValue ?? []

    // nil with the reason it is not an index into the sequence
    func index() throws -> (index: Int?, failure: NcMethodResult) {
      let index = try arguments.index()
      let failure = NcMethodResult.error(
        .indexOutOfBounds, "Index \(index) is beyond the \(items.count) items"
      )
      return (items.indices.contains(index) ? index : nil, failure)
    }

    switch method {
    case 3:
      let (index, failure) = try index()
      guard let index else { return failure }
      return NcMethodResult(value: items[index])
    case 4:
      let item = try arguments.value()
      let (index, failure) = try index()
      guard let index else { return failure }
      items[index] = item
      return await set(property, to: .array(items), session)
    case 5:
      try items.append(arguments.value())
      let result = await set(property, to: .array(items), session)
      guard !result.status.isError else { return result }
      // a device that keeps the sequence its own way may have taken the write and not
      // kept the item: one equal to another, where it holds no two alike
      let kept = await get(property, session).value?.arrayValue?.count
      guard kept == nil || kept == items.count else {
        return .error(.conflict, "The item was not added: the sequence has \(kept ?? 0) items")
      }
      return NcMethodResult(value: .integer(Int64(items.count - 1)))
    case 6:
      let (index, failure) = try index()
      guard let index else { return failure }
      items.remove(at: index)
      return await set(property, to: .array(items), session)
    default:
      // a sequence that is null has no length, which is not the same as none
      return NcMethodResult(value: value.isNull ? .null : .integer(Int64(items.count)))
    }
  }

  /// Whether a class in the object's lineage declares the property a sequence.
  private func isSequence(_ property: NcElementID) async -> Bool {
    let classes = await NcStandardModel.classes + source.classes()
    var classID: NcClassID? = identity.classID
    while let id = classID {
      if let declared = classes.first(where: { $0.classID == id })?.properties.first(where: { $0.id == property }) {
        return declared.isSequence
      }
      classID = id.ncParent
    }
    return false
  }

  private static func notASequence(_ property: NcElementID) -> NcMethodResult {
    .error(.invalidRequest, "Property \(property.level)p\(property.index) is not a sequence")
  }

  private static func noProperty(_ property: NcElementID) -> NcMethodResult {
    .error(.propertyNotImplemented, "No property \(property.level)p\(property.index)")
  }

  static func readOnly(_ property: NcElementID) -> NcMethodResult {
    .error(.readonly, "Property \(property.level)p\(property.index) is read only")
  }
}

/// `NcBlock`: its members, and the methods that find them.
final class NcBlock<Source: NcObjectSource>: NcObject<Source> {
  override func handleCommand(
    _ command: NcCommand,
    _ arguments: NcArguments,
    _ session: NcSession
  ) async throws -> NcMethodResult {
    guard command.methodID.level == 2, (1...4).contains(command.methodID.index) else {
      return try await super.handleCommand(command, arguments, session)
    }
    return try await blockMethod(command.methodID.index, arguments, session)
  }

  override func get(_ property: NcElementID, _ session: NcSession) async -> NcMethodResult {
    guard property == .members else { return await super.get(property, session) }
    let members = await descriptors(of: identity, recurse: false, session)
    return NcMethodResult(value: .array(members.map(\.member.json)))
  }

  override func set(_ property: NcElementID, to value: NMOSJSONValue, _ session: NcSession) async -> NcMethodResult {
    guard property == .members else { return await super.set(property, to: value, session) }
    return Self.readOnly(property)
  }

  private func blockMethod(
    _ method: UInt16,
    _ arguments: NcArguments,
    _ session: NcSession
  ) async throws -> NcMethodResult {
    let found: [NcBlockMemberDescriptor]
    switch method {
    case 1:
      found = try await descriptors(of: identity, recurse: arguments.bool("recurse"), session).map(\.member)
    case 2:
      let path = try arguments.strings("path")
      guard !path.isEmpty else { throw NcArgumentError("The path to search for is empty") }
      let members = await descriptors(of: identity, recurse: true, session)
      guard let member = members.first(where: { $0.path == path }) else {
        return .error(.badOid, "No member at \(path.joined(separator: "/"))")
      }
      found = [member.member]
    case 3:
      let role = try arguments.string("role")
      guard !role.isEmpty else { throw NcArgumentError("The role to search for is empty") }
      let caseSensitive = try arguments.bool("caseSensitive")
      let wholeString = try arguments.bool("matchWholeString")
      let sought = caseSensitive ? role : role.lowercased()
      found = try await descriptors(of: identity, recurse: arguments.bool("recurse"), session).map(\.member)
        .filter { member in
          let candidate = caseSensitive ? member.role : member.role.lowercased()
          return wholeString ? candidate == sought : candidate.contains(sought)
        }
    default:
      guard let classID = try NcClassID(json: arguments.required("classId")), !classID.isEmpty else {
        throw NcArgumentError("classId is not a class ID")
      }
      let includeDerived = try arguments.bool("includeDerived")
      found = try await descriptors(of: identity, recurse: arguments.bool("recurse"), session).map(\.member)
        .filter { includeDerived ? $0.classID.starts(with: classID) : $0.classID == classID }
    }
    return NcMethodResult(value: .array(found.map(\.json)))
  }

  private func descriptor(of member: Source.Identity, _ session: NcSession) async -> NcBlockMemberDescriptor {
    await NcBlockMemberDescriptor(
      role: member.role,
      oid: member.oid,
      constantOid: member.constantOid,
      classID: member.classID,
      userLabel: source.get(.userLabel, of: member, session: session).value?.stringValue,
      owner: member.owner ?? identity.oid
    )
  }

  /// The block's members with their role paths relative to it, depth first.
  private func descriptors(
    of block: Source.Identity,
    recurse: Bool,
    under path: [String] = [],
    _ session: NcSession
  ) async -> [(path: [String], member: NcBlockMemberDescriptor)] {
    var found = [(path: [String], member: NcBlockMemberDescriptor)]()
    for member in await source.members(of: block) {
      let descriptor = await descriptor(of: member, session)
      let path = path + [member.role]
      found.append((path, descriptor))
      if recurse, member.classID.starts(with: NcStandardModel.block) {
        found += await descriptors(of: member, recurse: true, under: path, session)
      }
    }
    return found
  }
}

/// `NcClassManager`: the classes and datatypes, the standard ones and the source's.
final class NcClassManager<Source: NcObjectSource>: NcObject<Source> {
  override func handleCommand(
    _ command: NcCommand,
    _ arguments: NcArguments,
    _ session: NcSession
  ) async throws -> NcMethodResult {
    guard command.methodID.level == 3, (1...2).contains(command.methodID.index) else {
      return try await super.handleCommand(command, arguments, session)
    }
    return try await classManagerMethod(command.methodID.index, arguments)
  }

  override func get(_ property: NcElementID, _ session: NcSession) async -> NcMethodResult {
    switch (property.level, property.index) {
    case (3, 1): await NcMethodResult(value: descriptorLists().classes)
    case (3, 2): await NcMethodResult(value: descriptorLists().datatypes)
    default: await super.get(property, session)
    }
  }

  override func set(_ property: NcElementID, to value: NMOSJSONValue, _ session: NcSession) async -> NcMethodResult {
    guard property.level == 3, (1...2).contains(property.index) else {
      return await super.set(property, to: value, session)
    }
    return Self.readOnly(property)
  }

  /// The descriptor of a class as `GetControlClass` answers with it, built on the
  /// first request for it and kept.
  private func classDescriptor(_ classID: NcClassID, inherited: Bool) async -> NMOSJSONValue? {
    let key = NcDescriptorCache.Key.controlClass(classID, inherited: inherited)
    // what is kept stands only while the source describes its classes as it did
    let lists = await descriptorLists()
    if let entry = model.descriptors.entry(for: key, in: lists) { return entry.json }

    let classes = NcStandardModel.classes + lists.sourceClasses
    guard var descriptor = classes.first(where: { $0.classID == classID }) else { return nil }
    var ancestor = classID.ncParent
    while inherited, let id = ancestor {
      // what each class it derives from defines, the root's first
      if let parent = classes.first(where: { $0.classID == id }) {
        descriptor.properties.insert(contentsOf: parent.properties, at: 0)
        descriptor.methods.insert(contentsOf: parent.methods, at: 0)
        descriptor.events.insert(contentsOf: parent.events, at: 0)
      }
      ancestor = id.ncParent
    }
    return model.descriptors.keep(.init(json: descriptor.json), for: key, in: lists).json
  }

  /// The descriptor of a datatype as `GetDatatype` answers with it, kept likewise.
  private func datatypeDescriptor(_ name: String, inherited: Bool) async -> NMOSJSONValue? {
    let key = NcDescriptorCache.Key.datatype(name, inherited: inherited)
    let lists = await descriptorLists()
    if let entry = model.descriptors.entry(for: key, in: lists) { return entry.json }

    let datatypes = NcStandardModel.datatypes + lists.sourceDatatypes
    guard var descriptor = datatypes.first(where: { $0.name == name }) else { return nil }
    if inherited, case .struct(var fields, let parentType) = descriptor.kind {
      // with the fields of every struct it extends
      var ancestor = parentType
      while let name = ancestor,
            case let .struct(inheritedFields, parent)? = datatypes.first(where: { $0.name == name })?.kind
      {
        fields.insert(contentsOf: inheritedFields, at: 0)
        ancestor = parent
      }
      descriptor = NcDatatypeDescriptor(
        description: descriptor.description,
        name: descriptor.name,
        kind: .struct(fields: fields, parentType: parentType),
        constraints: descriptor.constraints
      )
    }
    return model.descriptors.keep(.init(json: descriptor.json), for: key, in: lists).json
  }

  /// The value of `controlClasses` or `datatypes`: every descriptor there is, which
  /// depends on which classes the source has objects of and is made again only when
  /// the source's own lists change.
  private func descriptorLists() async -> NcDescriptorCache.Lists {
    let classes = await source.classes(), datatypes = await source.datatypes()
    return model.descriptors.lists(classes: classes, datatypes: datatypes)
  }

  private func classManagerMethod(_ method: UInt16, _ arguments: NcArguments) async throws -> NcMethodResult {
    let includeInherited = try arguments.bool("includeInherited")
    if method == 1 {
      guard let classID = try NcClassID(json: arguments.required("classId")) else {
        throw NcArgumentError("classId is not a class ID")
      }
      guard let descriptor = await classDescriptor(classID, inherited: includeInherited) else {
        return .error(.parameterError, "No class \(classID)")
      }
      return NcMethodResult(value: descriptor)
    }

    let name = try arguments.string("name")
    guard let descriptor = await datatypeDescriptor(name, inherited: includeInherited) else {
      return .error(.parameterError, "No datatype \(name)")
    }
    return NcMethodResult(value: descriptor)
  }
}

/// `NcDeviceManager`: the version of MS-05-02 the model is of. The rest is the source's.
final class NcDeviceManager<Source: NcObjectSource>: NcObject<Source> {
  override func get(_ property: NcElementID, _ session: NcSession) async -> NcMethodResult {
    guard property == Self.ncVersion else { return await super.get(property, session) }
    return NcMethodResult(value: .string(NcStandardModel.version))
  }

  private static var ncVersion: NcElementID { NcElementID(level: 3, index: 1) }
}
