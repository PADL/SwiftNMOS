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
import Synchronization

/// What `NcObject` says of an object, apart from its user label.
public struct NcObjectIdentity: Sendable, Hashable {
  public var classID: NcClassID
  public var oid: NcOid
  /// Whether the object keeps this oid across restarts.
  public var constantOid: Bool
  /// The block that contains the object; nil only for the root block.
  public var owner: NcOid?
  public var role: String
  public var touchpoints: [NcTouchpoint]?

  public init(
    classID: NcClassID,
    oid: NcOid,
    constantOid: Bool = true,
    owner: NcOid?,
    role: String,
    touchpoints: [NcTouchpoint]? = nil
  ) {
    self.classID = classID
    self.oid = oid
    self.constantOid = constantOid
    self.owner = owner
    self.role = role
    self.touchpoints = touchpoints
  }

  public var isBlock: Bool { classID.starts(with: NcStandardModel.block) }
  public var isClassManager: Bool { classID.starts(with: NcStandardModel.classManager) }
}

/// The objects an `NcObjectModel` is a model of. A source supplies each object's
/// identity, the members of its blocks and its properties; the model supplies what
/// MS-05-02 specifies of every object, block and class manager.
public protocol NcObjectSource: Sendable {
  /// The object's identity, nil if there is no such object. The root block is oid 1.
  func identity(of oid: NcOid) async -> NcObjectIdentity?

  /// The objects a block directly contains, in a stable order.
  func members(of block: NcOid) async -> [NcOid]

  /// Reads a property for a session: the user label (1p6), and everything below
  /// `NcObject` except a block's members. An ID the object's class does not have is
  /// `propertyNotImplemented`.
  func get(_ property: NcElementID, of oid: NcOid, session: NcSession) async -> NcMethodResult

  /// Writes a property `get` reads; one that cannot be written is `readonly`.
  func set(
    _ property: NcElementID,
    of oid: NcOid,
    to value: NMOSJSONValue,
    session: NcSession
  ) async -> NcMethodResult

  /// The constraints on the object's properties that are its own and not its class's
  /// (`runtimePropertyConstraints`, 1p8), as `NcPropertyConstraints` objects; empty if
  /// it has none.
  func runtimeConstraints(of oid: NcOid, session: NcSession) async -> [NMOSJSONValue]

  /// A method no standard class of the model defines.
  func invoke(
    oid: NcOid,
    methodID: NcElementID,
    arguments: [String: NMOSJSONValue],
    session: NcSession
  ) async -> NcMethodResult

  /// The classes and datatypes of the objects that are not standard ones. The class
  /// manager asks for them at every lookup, so a source should keep the lists it
  /// returns until they change rather than make them each time.
  func classes() async -> [NcClassDescriptor]
  func datatypes() async -> [NcDatatypeDescriptor]

  /// The session's events, its subscriptions, and its end, as `NcDeviceModel` has them.
  func notifications(for session: NcSession) -> AsyncStream<NcNotification>
  func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async
  func sessionEnded(_ session: NcSession) async
}

public extension NcObjectSource {
  func invoke(
    oid: NcOid,
    methodID: NcElementID,
    arguments: [String: NMOSJSONValue],
    session: NcSession
  ) async -> NcMethodResult {
    .error(.methodNotImplemented, "No method \(methodID.level)m\(methodID.index)")
  }

  func runtimeConstraints(of oid: NcOid, session: NcSession) async -> [NMOSJSONValue] { [] }
  func classes() async -> [NcClassDescriptor] { [] }
  func datatypes() async -> [NcDatatypeDescriptor] { [] }
  func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {}
  func sessionEnded(_ session: NcSession) async {}
}

/// An MS-05-02 device model over a source of objects. It implements the methods of
/// `NcObject` and `NcBlock`, and those of `NcClassManager` for the object the source
/// presents as one, from the classes and datatypes the source describes.
public final class NcObjectModel<Source: NcObjectSource>: NcDeviceModel {
  public static var rootOid: NcOid { 1 }

  public let source: Source

  /// Where each open session's events go.
  private let listeners = Mutex([NcSession: AsyncStream<NcNotification>.Continuation]())
  private let descriptors = NcDescriptorCache()

  public init(source: Source) {
    self.source = source
  }

  // MARK: - NcDeviceModel

  public func invoke(
    oid: NcOid,
    methodID: NcElementID,
    arguments: [String: NMOSJSONValue],
    session: NcSession
  ) async -> NcMethodResult {
    guard let object = await identity(of: oid) else {
      return .error(.badOid, "No object with oid \(oid)")
    }
    do {
      let arguments = Arguments(arguments)
      switch (methodID.level, methodID.index) {
      case (1, 1):
        return try await get(arguments.propertyID(), of: object, session)
      case (1, 2):
        return try await set(arguments.propertyID(), of: object, to: arguments.value(), session)
      case (1, 3...7):
        return try await sequence(methodID.index, of: object, arguments, session)
      case (2, 1...4) where object.isBlock:
        return try await block(methodID.index, of: object, arguments, session)
      case (3, 1...2) where object.isClassManager:
        return try await classManager(methodID.index, arguments)
      default:
        return await source.invoke(
          oid: oid, methodID: methodID, arguments: arguments.values, session: session
        )
      }
    } catch let error as ArgumentError {
      return .error(.parameterError, error.message)
    } catch {
      return .error(.deviceError, "\(error)")
    }
  }

  public func subscribable(_ oids: [NcOid], session: NcSession) async -> [NcOid] {
    var existing = [NcOid]()
    for oid in oids where await identity(of: oid) != nil {
      existing.append(oid)
    }
    return existing
  }

  public func notifications(for session: NcSession) -> AsyncStream<NcNotification> {
    let (stream, continuation) = AsyncStream<NcNotification>.makeStream()
    listeners.withLock { $0[session] = continuation }
    let upstream = source.notifications(for: session)
    let task = Task {
      for await notification in upstream { continuation.yield(notification) }
      continuation.finish()
    }
    continuation.onTermination = { [weak self] _ in
      task.cancel()
      self?.listeners.withLock { $0[session] = nil }
    }
    return stream
  }

  public func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {
    await source.subscriptionsChanged(to: oids, session: session)
  }

  public func sessionEnded(_ session: NcSession) async {
    listeners.withLock { $0.removeValue(forKey: session) }?.finish()
    await source.sessionEnded(session)
  }

  // MARK: - Objects

  private func identity(of oid: NcOid) async -> NcObjectIdentity? {
    await source.identity(of: oid)
  }

  private func members(of block: NcOid) async -> [NcOid] {
    await source.members(of: block)
  }

  private func userLabel(of oid: NcOid, _ session: NcSession) async -> NcMethodResult {
    await source.get(.userLabel, of: oid, session: session)
  }

  private func descriptor(
    of oid: NcOid,
    in block: NcOid,
    _ session: NcSession
  ) async -> NcBlockMemberDescriptor? {
    guard let member = await identity(of: oid) else { return nil }
    return await NcBlockMemberDescriptor(
      role: member.role,
      oid: oid,
      constantOid: member.constantOid,
      classID: member.classID,
      userLabel: userLabel(of: oid, session).value?.stringValue,
      owner: block
    )
  }

  /// The block's members with their role paths relative to it, depth first.
  private func descriptors(
    of block: NcOid,
    recurse: Bool,
    under path: [String] = [],
    _ session: NcSession
  ) async -> [(path: [String], member: NcBlockMemberDescriptor)] {
    var found = [(path: [String], member: NcBlockMemberDescriptor)]()
    for oid in await members(of: block) {
      guard let member = await descriptor(of: oid, in: block, session) else { continue }
      let path = path + [member.role]
      found.append((path, member))
      if recurse, member.classID.starts(with: NcStandardModel.block) {
        found += await descriptors(of: oid, recurse: true, under: path, session)
      }
    }
    return found
  }

  // MARK: - NcObject

  private func get(
    _ property: NcElementID,
    of object: NcObjectIdentity,
    _ session: NcSession
  ) async -> NcMethodResult {
    switch (property.level, property.index) {
    case (1, 1): return NcMethodResult(value: object.classID.json)
    case (1, 2): return NcMethodResult(value: .integer(Int64(object.oid)))
    case (1, 3): return NcMethodResult(value: .bool(object.constantOid))
    case (1, 4): return NcMethodResult(value: object.owner.map { .integer(Int64($0)) } ?? .null)
    case (1, 5): return NcMethodResult(value: .string(object.role))
    case (1, 6): return await userLabel(of: object.oid, session)
    case (1, 7): return NcMethodResult(value: object.touchpoints.map { .array($0.map(\.json)) } ?? .null)
    case (1, 8):
      let constraints = await source.runtimeConstraints(of: object.oid, session: session)
      return NcMethodResult(value: constraints.isEmpty ? .null : .array(constraints))
    case (1, _): return Self.noProperty(property)
    case (2, 2) where object.isBlock:
      let members = await descriptors(of: object.oid, recurse: false, session)
      return NcMethodResult(value: .array(members.map(\.member.json)))
    default:
      break
    }
    switch (property.level, property.index) {
    case (3, 1) where object.isClassManager: return await NcMethodResult(value: descriptorLists().classes)
    case (3, 2) where object.isClassManager: return await NcMethodResult(value: descriptorLists().datatypes)
    default: return await source.get(property, of: object.oid, session: session)
    }
  }

  private func set(
    _ property: NcElementID,
    of object: NcObjectIdentity,
    to value: NMOSJSONValue,
    _ session: NcSession
  ) async -> NcMethodResult {
    switch (property.level, property.index) {
    case (1, 6):
      break
    case (1, 1...8):
      return Self.readOnly(property)
    case (1, _):
      return Self.noProperty(property)
    case (2, 2) where object.isBlock:
      return Self.readOnly(property)
    default:
      break
    }
    if object.isClassManager, property.level == 3, (1...2).contains(property.index) {
      return Self.readOnly(property)
    }
    return await source.set(property, of: object.oid, to: value, session: session)
  }

  /// The sequence methods, 1m3 to 1m7, in terms of reading and writing the whole value.
  private func sequence(
    _ method: UInt16,
    of object: NcObjectIdentity,
    _ arguments: Arguments,
    _ session: NcSession
  ) async throws -> NcMethodResult {
    let property = try arguments.propertyID()
    let current = await get(property, of: object, session)
    guard !current.status.isError else { return current }
    guard let value = current.value, value.isNull || value.arrayValue != nil else {
      return .error(.invalidRequest, "Property \(property.level)p\(property.index) is not a sequence")
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
      return await set(property, of: object, to: .array(items), session)
    case 5:
      try items.append(arguments.value())
      let result = await set(property, of: object, to: .array(items), session)
      guard !result.status.isError else { return result }
      // a device that keeps the sequence its own way may have taken the write and not
      // kept the item: one equal to another, where it holds no two alike
      let kept = await get(property, of: object, session).value?.arrayValue?.count
      guard kept == nil || kept == items.count else {
        return .error(.conflict, "The item was not added: the sequence has \(kept ?? 0) items")
      }
      return NcMethodResult(value: .integer(Int64(items.count - 1)))
    case 6:
      let (index, failure) = try index()
      guard let index else { return failure }
      items.remove(at: index)
      return await set(property, of: object, to: .array(items), session)
    default:
      // a sequence that is null has no length, which is not the same as none
      return NcMethodResult(value: value.isNull ? .null : .integer(Int64(items.count)))
    }
  }

  // MARK: - NcBlock

  private func block(
    _ method: UInt16,
    of block: NcObjectIdentity,
    _ arguments: Arguments,
    _ session: NcSession
  ) async throws -> NcMethodResult {
    let found: [NcBlockMemberDescriptor]
    switch method {
    case 1:
      found = try await descriptors(of: block.oid, recurse: arguments.bool("recurse"), session).map(\.member)
    case 2:
      let path = try arguments.strings("path")
      guard !path.isEmpty else { throw ArgumentError("The path to search for is empty") }
      let members = await descriptors(of: block.oid, recurse: true, session)
      guard let member = members.first(where: { $0.path == path }) else {
        return .error(.badOid, "No member at \(path.joined(separator: "/"))")
      }
      found = [member.member]
    case 3:
      let role = try arguments.string("role")
      guard !role.isEmpty else { throw ArgumentError("The role to search for is empty") }
      let caseSensitive = try arguments.bool("caseSensitive")
      let wholeString = try arguments.bool("matchWholeString")
      let sought = caseSensitive ? role : role.lowercased()
      found = try await descriptors(of: block.oid, recurse: arguments.bool("recurse"), session).map(\.member)
        .filter { member in
          let candidate = caseSensitive ? member.role : member.role.lowercased()
          return wholeString ? candidate == sought : candidate.contains(sought)
        }
    default:
      guard let classID = try NcClassID(json: arguments.required("classId")), !classID.isEmpty else {
        throw ArgumentError("classId is not a class ID")
      }
      let includeDerived = try arguments.bool("includeDerived")
      found = try await descriptors(of: block.oid, recurse: arguments.bool("recurse"), session).map(\.member)
        .filter { includeDerived ? $0.classID.starts(with: classID) : $0.classID == classID }
    }
    return NcMethodResult(value: .array(found.map(\.json)))
  }

  // MARK: - NcClassManager

  /// The descriptor of a class as `GetControlClass` answers with it, built on the
  /// first request for it and kept.
  private func classDescriptor(_ classID: NcClassID, inherited: Bool) async -> NMOSJSONValue? {
    let key = NcDescriptorCache.Key.controlClass(classID, inherited: inherited)
    if let entry = descriptors.entry(for: key) { return entry.json }

    let classes = await NcStandardModel.classes + source.classes()
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
    return descriptors.keep(.init(json: descriptor.json), for: key).json
  }

  /// The descriptor of a datatype as `GetDatatype` answers with it, kept likewise.
  private func datatypeDescriptor(_ name: String, inherited: Bool) async -> NMOSJSONValue? {
    let key = NcDescriptorCache.Key.datatype(name, inherited: inherited)
    if let entry = descriptors.entry(for: key) { return entry.json }

    let datatypes = await NcStandardModel.datatypes + source.datatypes()
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
      descriptor.kind = .struct(fields: fields, parentType: parentType)
    }
    return descriptors.keep(.init(json: descriptor.json), for: key).json
  }

  /// The value of `controlClasses` or `datatypes`: every descriptor there is, which
  /// depends on which classes the source has objects of and is made again only when
  /// the source's own lists change.
  private func descriptorLists() async -> NcDescriptorCache.Lists {
    let classes = await source.classes(), datatypes = await source.datatypes()
    return descriptors.lists(classes: classes, datatypes: datatypes)
  }

  private func classManager(_ method: UInt16, _ arguments: Arguments) async throws -> NcMethodResult {
    let includeInherited = try arguments.bool("includeInherited")
    if method == 1 {
      guard let classID = try NcClassID(json: arguments.required("classId")) else {
        throw ArgumentError("classId is not a class ID")
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

  // MARK: - Results

  private static func noProperty(_ property: NcElementID) -> NcMethodResult {
    .error(.propertyNotImplemented, "No property \(property.level)p\(property.index)")
  }

  private static func readOnly(_ property: NcElementID) -> NcMethodResult {
    .error(.readonly, "Property \(property.level)p\(property.index) is read only")
  }
}

public extension NcElementID {
  /// `NcObject.userLabel`, the one property of `NcObject` a controller can write.
  static let userLabel = Self(level: 1, index: 6)
}

/// The descriptors a class manager answers with, each put together once and shared by
/// every control session. Synchronous, and safe to use from any thread.
private final class NcDescriptorCache: Sendable {
  enum Key: Hashable, Sendable {
    case controlClass(NcClassID, inherited: Bool)
    case datatype(String, inherited: Bool)
  }

  struct Entry: Sendable {
    let json: NMOSJSONValue
  }

  /// Both lists as their properties return them, and what they were made from.
  struct Lists: Sendable {
    let sourceClasses: [NcClassDescriptor]
    let sourceDatatypes: [NcDatatypeDescriptor]
    let classes: NMOSJSONValue
    let datatypes: NMOSJSONValue
  }

  // An entry is never invalidated: a class ID or a datatype name stands for one
  // definition for as long as the process runs, so what was built for it once is
  // what it will always be. Only the lists depend on which classes have objects.
  private let _cache = Mutex([Key: Entry]())
  private let _lists = Mutex<Lists?>(nil)

  func entry(for key: Key) -> Entry? {
    _cache.withLock { $0[key] }
  }

  /// Stores an entry built outside the lock. Two callers that built the same entry at
  /// once built the same thing, and the first stored is the one both keep.
  func keep(_ entry: Entry, for key: Key) -> Entry {
    _cache.withLock { cache in
      if let existing = cache[key] { return existing }
      cache[key] = entry
      return entry
    }
  }

  /// The lists for what the source now has. A source that keeps its lists until they
  /// change hands back the same arrays, which compare without being read.
  func lists(classes: [NcClassDescriptor], datatypes: [NcDatatypeDescriptor]) -> Lists {
    if let lists = _lists.withLock({ $0 }), lists.sourceClasses == classes, lists.sourceDatatypes == datatypes {
      return lists
    }
    let lists = Lists(
      sourceClasses: classes,
      sourceDatatypes: datatypes,
      classes: .array((NcStandardModel.classes + classes).map(\.json)),
      datatypes: .array((NcStandardModel.datatypes + datatypes).map(\.json))
    )
    _lists.withLock { $0 = lists }
    return lists
  }
}

/// A method's arguments, read by the names its descriptor gives them. What is missing
/// or of the wrong type is a parameter error, reported under the command's handle.
private struct Arguments {
  let values: [String: NMOSJSONValue]

  init(_ values: [String: NMOSJSONValue]) {
    self.values = values
  }

  func required(_ name: String) throws -> NMOSJSONValue {
    guard let value = values[name] else { throw ArgumentError("Argument \(name) is missing") }
    return value
  }

  func propertyID() throws -> NcElementID {
    guard let id = try NcElementID(json: required("id")) else {
      throw ArgumentError("Argument id is not a property ID")
    }
    return id
  }

  /// The `value` argument, which may be null but must be given.
  func value() throws -> NMOSJSONValue { try required("value") }

  func index() throws -> Int {
    guard let index = try required("index").integerValue, index >= 0 else {
      throw ArgumentError("Argument index is not a sequence index")
    }
    return Int(index)
  }

  func bool(_ name: String) throws -> Bool {
    guard let value = try required(name).boolValue else {
      throw ArgumentError("Argument \(name) is not a boolean")
    }
    return value
  }

  func string(_ name: String) throws -> String {
    guard let value = try required(name).stringValue else {
      throw ArgumentError("Argument \(name) is not a string")
    }
    return value
  }

  func strings(_ name: String) throws -> [String] {
    guard let values = try required(name).arrayValue?.map(\.stringValue),
          let strings = values as? [String]
    else { throw ArgumentError("Argument \(name) is not a sequence of strings") }
    return strings
  }
}

private struct ArgumentError: Error {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}
