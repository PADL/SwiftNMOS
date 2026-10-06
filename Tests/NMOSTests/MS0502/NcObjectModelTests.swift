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
import Synchronization
import XCTest

/// A small device: a root block holding a device manager, a block of two workers, a
/// bare object and the class manager, which has no label. One worker is of a vendor class with a gain and a sequence of taps.
private final class FixtureObjectSource: NcObjectSource {
  typealias Object = NcOid

  static let vendorGain: NcClassID = [1, 2, 0, 1]
  static let gain = NcElementID(level: 3, index: 1)
  static let taps = NcElementID(level: 3, index: 2)
  static let tags = NcElementID(level: 3, index: 3)
  static let enabled = NcElementID(level: 2, index: 1)

  private struct Fixture {
    var identity: Identity
    var members = [NcOid]()
    var properties = [NcElementID: NMOSJSONValue]()
    var readOnly = Set<NcElementID>()
  }

  private let objects: Mutex<[NcOid: Fixture]>
  private let listeners = Mutex([NcSession: AsyncStream<NcNotification>.Continuation]())
  let subscriptions = Mutex([NcSession: Set<NcOid>]())
  let ended = Mutex([NcSession]())
  /// Classes of objects added after the model was first asked for its classes.
  let laterClasses = Mutex([NcClassDescriptor]())
  /// The constraints objects have at run time.
  let constraints = Mutex([NcOid: [NMOSJSONValue]]())

  init() {
    func object(
      _ oid: NcOid, _ classID: NcClassID, _ role: String, owner: NcOid?,
      members: [NcOid] = [], properties: [NcElementID: NMOSJSONValue] = [:], readOnly: Set<NcElementID> = []
    ) -> (NcOid, Fixture) {
      var properties = properties
      properties[.userLabel] = properties[.userLabel] ?? .null
      return (oid, Fixture(
        identity: Identity(classID: classID, oid: oid, owner: owner, role: role, object: oid),
        members: members, properties: properties, readOnly: readOnly
      ))
    }
    objects = Mutex(Dictionary(uniqueKeysWithValues: [
      object(1, NcStandardModel.block, "root", owner: nil, members: [2, 10, 20, 99],
             properties: [Self.enabled: true], readOnly: [Self.enabled]),
      object(2, NcStandardModel.deviceManager, "DeviceManager", owner: 1),
      object(10, NcStandardModel.block, "channels", owner: 1, members: [11, 12],
             properties: [Self.enabled: true, .userLabel: "Channels"], readOnly: [Self.enabled]),
      object(11, Self.vendorGain, "gain", owner: 10,
             properties: [
               Self.enabled: true, Self.gain: 0.5, Self.taps: [1, 2, 3], Self.tags: ["a", "b"],
             ]),
      object(12, NcStandardModel.worker, "Mute", owner: 10, properties: [Self.enabled: true]),
      object(20, NcStandardModel.object, "misc", owner: 1),
      object(99, NcStandardModel.classManager, "ClassManager", owner: 1, readOnly: [.userLabel]),
    ]))
  }

  func identity(of oid: NcOid) async -> Identity? { objects.withLock { $0[oid]?.identity } }

  func members(of block: Identity) async -> [Identity] {
    objects.withLock { objects in (objects[block.oid]?.members ?? []).compactMap { objects[$0]?.identity } }
  }

  func runtimeConstraints(of object: Identity, session: NcSession) async -> [NMOSJSONValue] {
    constraints.withLock { $0[object.oid] ?? [] }
  }

  func get(_ property: NcElementID, of object: Identity, session: NcSession) async -> NcMethodResult {
    let oid = object.oid
    guard let value = objects.withLock({ $0[oid]?.properties[property] }) else {
      return .error(.propertyNotImplemented, "no such property")
    }
    return NcMethodResult(value: value)
  }

  func set(
    _ property: NcElementID,
    of object: Identity,
    to value: NMOSJSONValue,
    session: NcSession
  ) async -> NcMethodResult {
    let oid = object.oid
    let result: NcMethodResult = objects.withLock { objects in
      guard let object = objects[oid], object.properties[property] != nil else {
        return .error(.propertyNotImplemented, "no such property")
      }
      guard !object.readOnly.contains(property) else { return .error(.readonly, "read only") }
      var value = value
      if property == Self.tags, let items = value.arrayValue {
        // a sequence the device keeps as a set: an item it already has is not kept again
        var seen = Set<NMOSJSONValue>()
        value = .array(items.filter { seen.insert($0).inserted })
      }
      objects[oid]?.properties[property] = value
      return NcMethodResult()
    }
    if !result.status.isError {
      let eventData = NcPropertyChangedEventData(propertyID: property, value: value)
      let notification = NcNotification(oid: oid, eventData: eventData.json)
      for listener in listeners.withLock({ Array($0.values) }) { listener.yield(notification) }
    }
    return result
  }

  func classes() async -> [NcClassDescriptor] {
    [NcClassDescriptor(classID: Self.vendorGain, name: "VendorGain", properties: [
      .init(id: Self.gain, name: "gain", typeName: "NcFloat32", isReadOnly: false),
      .init(id: Self.taps, name: "taps", typeName: "VendorTap", isReadOnly: false, isSequence: true),
    ])] + laterClasses.withLock { $0 }
  }

  func datatypes() async -> [NcDatatypeDescriptor] {
    [NcDatatypeDescriptor(name: "VendorTap", kind: .typedef(parentType: "NcInt32", isSequence: false))]
  }

  func notifications(for session: NcSession) -> AsyncStream<NcNotification> {
    let (stream, continuation) = AsyncStream<NcNotification>.makeStream()
    listeners.withLock { $0[session] = continuation }
    return stream
  }

  func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {
    subscriptions.withLock { $0[session] = oids }
  }

  func sessionEnded(_ session: NcSession) async {
    listeners.withLock { $0.removeValue(forKey: session) }?.finish()
    ended.withLock { $0.append(session) }
  }
}

final class NcObjectModelTests: XCTestCase {
  private typealias Source = FixtureObjectSource

  private let session = NcSession(peer: .ip("192.0.2.7", port: 49152))
  private var source: FixtureObjectSource!
  private var model: NcObjectModel<FixtureObjectSource>!

  override func setUp() {
    source = FixtureObjectSource()
    model = NcObjectModel(source: source)
  }

  private func invoke(_ oid: NcOid, _ level: UInt16, _ index: UInt16, _ arguments: [String: NMOSJSONValue] = [:]) async -> NcMethodResult {
    await model.handleCommand(
      NcCommand(oid: oid, methodID: .init(level: level, index: index), arguments: arguments),
      session: session
    )
  }

  private func get(_ oid: NcOid, _ level: UInt16, _ index: UInt16) async -> NcMethodResult {
    await invoke(oid, 1, 1, ["id": NcElementID(level: level, index: index).json])
  }

  private func set(_ oid: NcOid, _ level: UInt16, _ index: UInt16, _ value: NMOSJSONValue) async -> NcMethodResult {
    await invoke(oid, 1, 2, ["id": NcElementID(level: level, index: index).json, "value": value])
  }

  private func oids(_ result: NcMethodResult) -> [Int64] {
    result.value?.arrayValue?.compactMap { $0["oid"]?.integerValue } ?? []
  }

  // MARK: NcObject

  func testAnObjectHasThePropertiesOfNcObject() async {
    let values = await [
      get(11, 1, 1).value, get(11, 1, 2).value, get(11, 1, 3).value, get(11, 1, 4).value,
      get(11, 1, 5).value, get(11, 1, 6).value, get(11, 1, 7).value, get(11, 1, 8).value,
    ]
    XCTAssertEqual(values, [[1, 2, 0, 1], 11, true, 10, "gain", .null, .null, .null])
    // only the root block has no owner
    let rootOwner = await get(1, 1, 4)
    XCTAssertEqual(rootOwner.value, .null)
    XCTAssertEqual(rootOwner.status, .ok)
  }

  func testAnObjectsOwnConstraintsAreItsRuntimeConstraints() async {
    let range = NcPropertyConstraintsNumber(propertyID: FixtureObjectSource.gain, minimum: 0, maximum: 1)
    XCTAssertEqual(range.json, [
      "propertyId": ["level": 3, "index": 1], "defaultValue": .null, "minimum": 0, "maximum": 1, "step": .null,
    ])
    source.constraints.withLock { $0[11] = [range.json] }
    let constrained = await get(11, 1, 8)
    XCTAssertEqual(constrained.value, [range.json])
    // an object with none has null there, not an empty sequence
    let unconstrained = await get(12, 1, 8)
    XCTAssertEqual(unconstrained, NcMethodResult(value: .null))
  }

  func testStatusesFollowMS0502() async {
    let statuses = await [
      get(4242, 1, 2).status, get(11, 1, 999).status, get(11, 9, 1).status,
      invoke(11, 1, 999).status, invoke(11, 2, 1, ["recurse": true]).status,
      set(11, 1, 5, "role").status, set(1, 2, 2, []).status, set(1, 2, 1, false).status,
      set(11, 1, 999, 1).status, invoke(11, 1, 1).status, invoke(11, 1, 1, ["id": "1p6"]).status,
      invoke(11, 1, 2, ["id": NcElementID.userLabel.json]).status,
    ]
    XCTAssertEqual(statuses, [
      .badOid, .propertyNotImplemented, .propertyNotImplemented,
      // a block's methods are not a worker's
      .methodNotImplemented, .methodNotImplemented,
      .readonly, .readonly, .readonly,
      .propertyNotImplemented, .parameterError, .parameterError,
      .parameterError,
    ])
    let failure = await get(4242, 1, 2)
    XCTAssertNotNil(failure.errorMessage)
    XCTAssertNil(failure.value)
  }

  func testPropertiesBelowNcObjectAreTheSources() async {
    let before = await get(11, 3, 1)
    XCTAssertEqual(before.value, 0.5)
    let written = await set(11, 3, 1, 0.25)
    XCTAssertEqual(written, NcMethodResult())
    let after = await get(11, 3, 1)
    XCTAssertEqual(after.value, 0.25)
    let label = await set(11, 1, 6, "Left")
    XCTAssertEqual(label.status, .ok)
    let read = await get(11, 1, 6)
    XCTAssertEqual(read.value, "Left")
  }

  func testSequenceMethodsWorkOnTheWholeValue() async {
    let taps = Source.taps.json
    let length = await invoke(11, 1, 7, ["id": taps])
    XCTAssertEqual(length.value, 3)
    let item = await invoke(11, 1, 3, ["id": taps, "index": 1])
    XCTAssertEqual(item.value, 2)
    let changed = await invoke(11, 1, 4, ["id": taps, "index": 1, "value": 20])
    XCTAssertEqual(changed, NcMethodResult())
    let added = await invoke(11, 1, 5, ["id": taps, "value": 4])
    XCTAssertEqual(added.value, 3)
    let removed = await invoke(11, 1, 6, ["id": taps, "index": 0])
    XCTAssertEqual(removed, NcMethodResult())
    let value = await get(11, 3, 2)
    XCTAssertEqual(value.value, [20, 3, 4])

    // an item the device takes but does not keep was not added
    let tags = Source.tags.json
    let kept = await invoke(11, 1, 5, ["id": tags, "value": "c"])
    XCTAssertEqual(kept.value, 2)
    let dropped = await invoke(11, 1, 5, ["id": tags, "value": "a"])
    XCTAssertEqual(dropped.status, .conflict)
    XCTAssertNil(dropped.value)

    let statuses = await [
      invoke(11, 1, 3, ["id": taps, "index": 3]).status,
      invoke(11, 1, 6, ["id": taps, "index": 13]).status,
      invoke(11, 1, 3, ["id": taps]).status,
      invoke(11, 1, 3, ["id": taps, "index": -1]).status,
      // not a sequence, and a sequence that cannot be written
      invoke(11, 1, 7, ["id": Source.gain.json]).status,
      invoke(1, 1, 5, ["id": NcElementID(level: 2, index: 2).json, "value": [:]]).status,
      invoke(11, 1, 7, ["id": NcElementID(level: 3, index: 9).json]).status,
    ]
    XCTAssertEqual(statuses, [
      .indexOutOfBounds, .indexOutOfBounds, .parameterError, .parameterError,
      .invalidRequest, .readonly, .propertyNotImplemented,
    ])
    // a nullable sequence that is null has a null length
    let touchpoints = await invoke(11, 1, 7, ["id": NcElementID(level: 1, index: 7).json])
    XCTAssertEqual(touchpoints, NcMethodResult(value: .null))
  }

  // MARK: NcBlock

  func testTheRootBlockContainsTheClassManager() async {
    let members = await get(1, 2, 2)
    XCTAssertEqual(oids(members), [2, 10, 20, 99])
    let manager = members.value?.arrayValue?.last
    XCTAssertEqual(manager, NcBlockMemberDescriptor(
      role: "ClassManager", oid: 99, constantOid: true, classID: NcStandardModel.classManager,
      userLabel: nil, owner: 1
    ).json)
    let identity = await [get(99, 1, 1).value, get(99, 1, 4).value, get(99, 1, 5).value]
    XCTAssertEqual(identity, [[1, 3, 2], 1, "ClassManager"])
  }

  func testMemberDescriptorsCarryEachMembersLabelAndOwner() async {
    let direct = await invoke(1, 2, 1, ["recurse": false])
    XCTAssertEqual(oids(direct), [2, 10, 20, 99])
    let all = await invoke(1, 2, 1, ["recurse": true])
    XCTAssertEqual(oids(all), [2, 10, 11, 12, 20, 99])
    let channels = all.value?.arrayValue?[1]
    XCTAssertEqual(channels?["userLabel"], "Channels")
    XCTAssertEqual(all.value?.arrayValue?[2]["owner"], 10)
    let length = await invoke(1, 1, 7, ["id": NcElementID(level: 2, index: 2).json])
    XCTAssertEqual(length.value, 4)
    let missing = await invoke(1, 2, 1)
    XCTAssertEqual(missing.status, .parameterError)
  }

  func testFindsMembersByPath() async {
    let found = await invoke(1, 2, 2, ["path": ["channels", "gain"]])
    XCTAssertEqual(oids(found), [11])
    let relative = await invoke(10, 2, 2, ["path": ["Mute"]])
    XCTAssertEqual(oids(relative), [12])
    let statuses = await [
      invoke(1, 2, 2, ["path": ["channels", "nothing"]]).status,
      invoke(1, 2, 2, ["path": []]).status,
      invoke(1, 2, 2, ["path": "channels"]).status,
    ]
    XCTAssertEqual(statuses, [.badOid, .parameterError, .parameterError])
  }

  func testFindsMembersByRole() async {
    func find(_ role: String, caseSensitive: Bool, whole: Bool, recurse: Bool) async -> [Int64] {
      await oids(invoke(1, 2, 3, [
        "role": .string(role), "caseSensitive": .bool(caseSensitive),
        "matchWholeString": .bool(whole), "recurse": .bool(recurse),
      ]))
    }
    let exact = await find("Mute", caseSensitive: true, whole: true, recurse: true)
    XCTAssertEqual(exact, [12])
    let wrongCase = await find("MUTE", caseSensitive: true, whole: true, recurse: true)
    XCTAssertEqual(wrongCase, [])
    let anyCase = await find("MUTE", caseSensitive: false, whole: true, recurse: true)
    XCTAssertEqual(anyCase, [12])
    let notRecursive = await find("Mute", caseSensitive: true, whole: true, recurse: false)
    XCTAssertEqual(notRecursive, [])
    let part = await find("manager", caseSensitive: false, whole: false, recurse: false)
    XCTAssertEqual(part, [2, 99])
    let partCased = await find("manager", caseSensitive: true, whole: false, recurse: false)
    XCTAssertEqual(partCased, [])
  }

  func testFindsMembersByClass() async {
    func find(_ classID: NcClassID, derived: Bool, recurse: Bool) async -> [Int64] {
      await oids(invoke(1, 2, 4, [
        "classId": classID.json, "includeDerived": .bool(derived), "recurse": .bool(recurse),
      ]))
    }
    let workers = await find(NcStandardModel.worker, derived: false, recurse: true)
    XCTAssertEqual(workers, [12])
    let derived = await find(NcStandardModel.worker, derived: true, recurse: true)
    XCTAssertEqual(derived, [11, 12])
    let managers = await find(NcStandardModel.manager, derived: true, recurse: false)
    XCTAssertEqual(managers, [2, 99])
    let everything = await find(NcStandardModel.object, derived: true, recurse: true)
    XCTAssertEqual(everything, [2, 10, 11, 12, 20, 99])
    let onlyObjects = await find(NcStandardModel.object, derived: false, recurse: true)
    XCTAssertEqual(onlyObjects, [20])
  }

  // MARK: NcClassManager

  func testTheClassManagerPublishesStandardAndSourceDescriptors() async throws {
    let controlClasses = await get(99, 3, 1)
    let classes = try XCTUnwrap(controlClasses.value?.arrayValue)
    XCTAssertEqual(classes.count, NcStandardModel.classes.count + 1)
    XCTAssertEqual(classes.last?["name"], "VendorGain")
    let allDatatypes = await get(99, 3, 2)
    let datatypes = try XCTUnwrap(allDatatypes.value?.arrayValue)
    XCTAssertEqual(datatypes.last?["name"], "VendorTap")
    let statuses = await [set(99, 3, 1, []).status, get(99, 3, 3).status, get(99, 2, 1).status]
    XCTAssertEqual(statuses, [.readonly, .propertyNotImplemented, .propertyNotImplemented])
  }

  func testGetControlClassCanIncludeWhatIsInherited() async throws {
    let own = await invoke(99, 3, 1, ["classId": Source.vendorGain.json, "includeInherited": false])
    XCTAssertEqual(own.value?["properties"]?.arrayValue?.count, 2)
    XCTAssertEqual(own.value?["methods"]?.arrayValue?.count, 0)

    let all = await invoke(99, 3, 1, ["classId": Source.vendorGain.json, "includeInherited": true])
    let names = all.value?["properties"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
    // NcObject's eight, NcWorker's one, then its own
    XCTAssertEqual(names?.count, 11)
    XCTAssertEqual(names?.first, "classId")
    XCTAssertEqual(names?.suffix(3), ["enabled", "gain", "taps"])
    XCTAssertEqual(all.value?["methods"]?.arrayValue?.count, 7)
    XCTAssertEqual(all.value?["events"]?.arrayValue?.count, 1)
    XCTAssertEqual(all.value?["classId"], Source.vendorGain.json)

    let statuses = await [
      invoke(99, 3, 1, ["classId": [1, 9, 9], "includeInherited": true]).status,
      invoke(99, 3, 1, ["classId": [1, 2]]).status,
      invoke(99, 3, 1, ["classId": "NcWorker", "includeInherited": true]).status,
    ]
    XCTAssertEqual(statuses, [.parameterError, .parameterError, .parameterError])
  }

  func testGetDatatypeCanIncludeWhatIsInherited() async {
    let own = await invoke(99, 3, 2, ["name": "NcMethodResultError", "includeInherited": false])
    XCTAssertEqual(own.value?["fields"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["errorMessage"])
    let all = await invoke(99, 3, 2, ["name": "NcMethodResultError", "includeInherited": true])
    XCTAssertEqual(
      all.value?["fields"]?.arrayValue?.compactMap { $0["name"]?.stringValue },
      ["status", "errorMessage"]
    )
    XCTAssertEqual(all.value?["parentType"], "NcMethodResult")
    let vendor = await invoke(99, 3, 2, ["name": "VendorTap", "includeInherited": true])
    XCTAssertEqual(vendor.value?["parentType"], "NcInt32")
    let unknown = await invoke(99, 3, 2, ["name": "NcNothing", "includeInherited": true])
    XCTAssertEqual(unknown.status, .parameterError)
  }

  func testDescriptorsAreKeptAndAClassMetLaterIsAdded() async throws {
    let vendor = Source.vendorGain.json
    let first = await invoke(99, 3, 1, ["classId": vendor, "includeInherited": true])
    let second = await invoke(99, 3, 1, ["classId": vendor, "includeInherited": true])
    XCTAssertEqual(first, second)
    let own = await invoke(99, 3, 1, ["classId": vendor, "includeInherited": false])
    XCTAssertNotEqual(own, first)
    let listed = await get(99, 3, 1)
    let datatype = await invoke(99, 3, 2, ["name": "NcTouchpointNmos", "includeInherited": true])
    let again = await invoke(99, 3, 2, ["name": "NcTouchpointNmos", "includeInherited": true])
    XCTAssertEqual(datatype, again)

    // an object of a class the device did not have before
    let later: NcClassID = [1, 2, 0, 2]
    let unknown = await invoke(99, 3, 1, ["classId": later.json, "includeInherited": true])
    XCTAssertEqual(unknown.status, .parameterError)
    source.laterClasses.withLock { $0 = [NcClassDescriptor(classID: later, name: "VendorLater")] }
    let known = await invoke(99, 3, 1, ["classId": later.json, "includeInherited": true])
    XCTAssertEqual(known.value?["name"], "VendorLater")
    XCTAssertEqual(known.value?["properties"]?.arrayValue?.count, 9)
    let relisted = await get(99, 3, 1)
    XCTAssertEqual(relisted.value?.arrayValue?.count, (listed.value?.arrayValue?.count ?? 0) + 1)
    // what was there before is as it was
    let unchanged = await invoke(99, 3, 1, ["classId": vendor, "includeInherited": true])
    XCTAssertEqual(unchanged, first)
  }

  // MARK: Events

  func testOnlyObjectsThatExistCanBeSubscribedTo() async {
    let accepted = await model.subscribable([1, 11, 99, 4242], session: session)
    XCTAssertEqual(accepted, [1, 11, 99])
    // the class manager is the source's like any other object
    await model.subscriptionsChanged(to: [1, 99], session: session)
    XCTAssertEqual(source.subscriptions.withLock { $0 }, [session: [1, 99]])
  }

  func testChangesOfTheSourceAreNotified() async throws {
    var notifications = model.notifications(for: session).makeAsyncIterator()
    // the class manager has no label to change, as it could not keep one
    let label = await set(99, 1, 6, "Classes")
    XCTAssertEqual(label.status, .readonly)
    let read = await get(99, 1, 6)
    XCTAssertEqual(read.value, .null)

    _ = await set(11, 3, 1, 1.0)
    let first = await notifications.next()
    XCTAssertEqual(first?.oid, 11)
    XCTAssertEqual(first?.eventData["propertyId"], Source.gain.json)

    // a session that ends has its events end, and the source hears of it
    await model.sessionEnded(session)
    let last = await notifications.next()
    XCTAssertNil(last)
    XCTAssertEqual(source.ended.withLock { $0 }, [session])
  }
}
