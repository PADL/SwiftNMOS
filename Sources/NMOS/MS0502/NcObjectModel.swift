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

  public init(
    classID: NcClassID,
    oid: NcOid,
    constantOid: Bool = true,
    owner: NcOid?,
    role: String
  ) {
    self.classID = classID
    self.oid = oid
    self.constantOid = constantOid
    self.owner = owner
    self.role = role
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

  /// The resources of other specifications the object stands for (`touchpoints`, 1p7);
  /// nil if it stands for none. Asked only when 1p7 is read.
  func touchpoints(of oid: NcOid) async -> [NcTouchpoint]?

  /// The constraints on the object's properties that are its own and not its class's
  /// (`runtimePropertyConstraints`, 1p8), as `NcPropertyConstraints` objects; empty if
  /// it has none.
  func runtimeConstraints(of oid: NcOid, session: NcSession) async -> [NMOSJSONValue]

  /// A command for a method no standard class of the model defines.
  func handleCommand(_ command: NcCommand, session: NcSession) async -> NcMethodResult

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
  func handleCommand(_ command: NcCommand, session: NcSession) async -> NcMethodResult {
    .error(.methodNotImplemented, "No method \(command.methodID.level)m\(command.methodID.index)")
  }

  func runtimeConstraints(of oid: NcOid, session: NcSession) async -> [NMOSJSONValue] { [] }
  func touchpoints(of oid: NcOid) async -> [NcTouchpoint]? { nil }
  func classes() async -> [NcClassDescriptor] { [] }
  func datatypes() async -> [NcDatatypeDescriptor] { [] }
  func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {}
  func sessionEnded(_ session: NcSession) async {}
}

/// An MS-05-02 device model over a source of objects. Each object the source presents is
/// answered for as an `NcObject`, `NcBlock` or `NcClassManager` by its class, and what
/// none of them has is the source's.
public final class NcObjectModel<Source: NcObjectSource>: NcDeviceModel {
  public static var rootOid: NcOid { 1 }

  public let source: Source

  /// What the class manager answers with, shared by every session.
  let descriptors = NcDescriptorCache()
  let sequenceLocks = NcSequenceLocks()

  public init(source: Source) {
    self.source = source
  }

  // MARK: - NcDeviceModel

  public func handleCommand(_ command: NcCommand, session: NcSession) async -> NcMethodResult {
    guard let identity = await source.identity(of: command.oid) else {
      return .error(.badOid, "No object with oid \(command.oid)")
    }
    do {
      return try await object(identity).handleCommand(command, NcArguments(command.arguments), session)
    } catch let error as NcArgumentError {
      return .error(.parameterError, error.message)
    } catch {
      return .error(.deviceError, "\(error)")
    }
  }

  /// The object as the standard class it is of.
  func object(_ identity: NcObjectIdentity) -> NcObject<Source> {
    if identity.isClassManager { return NcClassManager(identity, model: self) }
    if identity.isBlock { return NcBlock(identity, model: self) }
    return NcObject(identity, model: self)
  }

  public func subscribable(_ oids: [NcOid], session: NcSession) async -> [NcOid] {
    var existing = [NcOid]()
    for oid in oids where await source.identity(of: oid) != nil {
      existing.append(oid)
    }
    return existing
  }

  /// The source's events for the session; the source ends them when the session ends.
  public func notifications(for session: NcSession) -> AsyncStream<NcNotification> {
    source.notifications(for: session)
  }

  public func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {
    await source.subscriptionsChanged(to: oids, session: session)
  }

  public func sessionEnded(_ session: NcSession) async {
    await source.sessionEnded(session)
  }
}

public extension NcElementID {
  /// `NcObject.userLabel`, the one property of `NcObject` a controller can write.
  static let userLabel = Self(level: 1, index: 6)
}

/// The descriptors a class manager answers with, each put together once and shared by
/// every control session. Synchronous, and safe to use from any thread.
final class NcDescriptorCache: Sendable {
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

  // The entries are built from the source's lists, so they go when the lists change:
  // a source may describe a class more fully once it has an object of it.
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
    _cache.withLock { $0.removeAll() }
    return lists
  }
}

/// Holds each sequence property while one session changes it, so that changes made by
/// reading the whole sequence and writing it back are made one at a time.
actor NcSequenceLocks {
  struct Key: Hashable, Sendable {
    let oid: NcOid
    let property: NcElementID
  }

  private var held = Set<Key>()
  private var waiting = [Key: [CheckedContinuation<Void, Never>]]()

  func acquire(_ key: Key) async {
    guard !held.insert(key).inserted else { return }
    await withCheckedContinuation { waiting[key, default: []].append($0) }
  }

  /// Hands the property to the next session waiting for it, if there is one.
  func release(_ key: Key) {
    guard var queue = waiting[key], !queue.isEmpty else {
      held.remove(key)
      return
    }
    let next = queue.removeFirst()
    waiting[key] = queue.isEmpty ? nil : queue
    next.resume()
  }
}

/// A method's arguments, read by the names its descriptor gives them. What is missing
/// or of the wrong type is a parameter error, reported under the command's handle.
struct NcArguments {
  let values: [String: NMOSJSONValue]

  init(_ values: [String: NMOSJSONValue]) {
    self.values = values
  }

  func required(_ name: String) throws -> NMOSJSONValue {
    guard let value = values[name] else { throw NcArgumentError("Argument \(name) is missing") }
    return value
  }

  func propertyID() throws -> NcElementID {
    guard let id = try NcElementID(json: required("id")) else {
      throw NcArgumentError("Argument id is not a property ID")
    }
    return id
  }

  /// The `value` argument, which may be null but must be given.
  func value() throws -> NMOSJSONValue { try required("value") }

  func index() throws -> Int {
    guard let index = try required("index").integerValue, index >= 0 else {
      throw NcArgumentError("Argument index is not a sequence index")
    }
    return Int(index)
  }

  func bool(_ name: String) throws -> Bool {
    guard let value = try required(name).boolValue else {
      throw NcArgumentError("Argument \(name) is not a boolean")
    }
    return value
  }

  func string(_ name: String) throws -> String {
    guard let value = try required(name).stringValue else {
      throw NcArgumentError("Argument \(name) is not a string")
    }
    return value
  }

  func strings(_ name: String) throws -> [String] {
    guard let values = try required(name).arrayValue?.map(\.stringValue),
          let strings = values as? [String]
    else { throw NcArgumentError("Argument \(name) is not a sequence of strings") }
    return strings
  }
}

struct NcArgumentError: Error {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}
