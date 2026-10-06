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
@testable import NMOSOCABridge
import SwiftOCA
import SwiftOCADevice
import Synchronization
import XCTest

/// A proprietary subclass of a standard class, with a property of its own.
private final class TrimmedGain: SwiftOCADevice.OcaGain {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), 1)
  }

  @OcaDeviceProperty(
    propertyID: OcaPropertyID("5.1"),
    getMethodID: OcaMethodID("5.1"),
    setMethodID: OcaMethodID("5.2")
  )
  var trim: OcaDB = 0

  @OcaDeviceProperty(
    propertyID: OcaPropertyID("5.2"),
    getMethodID: OcaMethodID("5.3"),
    setMethodID: OcaMethodID("5.4")
  )
  var routing = [OcaUint16: [OcaPortID]]()

  @OcaDeviceProperty(propertyID: OcaPropertyID("5.3"), getMethodID: OcaMethodID("5.5"))
  var note: OcaString?

  @OcaVectorDeviceProperty(
    xPropertyID: OcaPropertyID("5.4"),
    yPropertyID: OcaPropertyID("5.5"),
    getMethodID: OcaMethodID("5.6"),
    setMethodID: OcaMethodID("5.7")
  )
  var cellXY = OcaVector2D<OcaUint16>(x: 1, y: 2)
}

/// An object whose device does not let a controller rename it.
private final class FixedLabelGain: SwiftOCADevice.OcaGain {
  override func ensureWritable(by controller: any OcaController, command: Ocp1Command) async throws {
    try await super.ensureWritable(by: controller, command: command)
    // OcaWorker's SetLabel
    guard command.methodID != OcaMethodID("2.9") else { throw Ocp1Error.status(.permissionDenied) }
  }
}

/// An object locked against every controller but the one holding the lock.
private final class LockedLabelGain: SwiftOCADevice.OcaGain {
  override func ensureWritable(by controller: any OcaController, command: Ocp1Command) async throws {
    try await super.ensureWritable(by: controller, command: command)
    guard command.methodID != OcaMethodID("2.9") else { throw Ocp1Error.status(.locked) }
  }
}

/// An agent that keeps something for local controllers only, as a device's store of
/// its own configuration does: `secret` may be read, and `setting` written, only by one.
private final class LocalOnlyAgent: SwiftOCADevice.OcaAgent {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), 9)
  }

  @OcaDeviceProperty(
    propertyID: OcaPropertyID("3.1"),
    getMethodID: OcaMethodID("3.1"),
    setMethodID: OcaMethodID("3.2")
  )
  var secret = "hunter2"

  @OcaDeviceProperty(
    propertyID: OcaPropertyID("3.2"),
    getMethodID: OcaMethodID("3.3"),
    setMethodID: OcaMethodID("3.4")
  )
  var setting = "factory"

  override func ensureReadable(by controller: any OcaController, command: Ocp1Command) async throws {
    try await super.ensureReadable(by: controller, command: command)
    guard command.methodID != OcaMethodID("3.1") || controller.flags.contains(.isLocal) else {
      throw Ocp1Error.status(.permissionDenied)
    }
  }

  override func ensureWritable(by controller: any OcaController, command: Ocp1Command) async throws {
    try await super.ensureWritable(by: controller, command: command)
    guard controller.flags.contains(.isLocal) else { throw Ocp1Error.status(.permissionDenied) }
  }
}

/// A pan whose device has no way to change its midpoint gain, though OCA gives it a setter.
private final class FixedMidpointPan: SwiftOCADevice.OcaPanBalance {
  override func handleCommand(
    _ command: Ocp1Command,
    from controller: any OcaController
  ) async throws -> Ocp1Response {
    if command.methodID == OcaMethodID("4.4") { throw Ocp1Error.status(.notImplemented) }
    return try await super.handleCommand(command, from: controller)
  }
}

/// An agent the device will not let a controller on the network read, its label included.
private final class SealedAgent: SwiftOCADevice.OcaAgent {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), 10)
  }

  override func ensureReadable(by controller: any OcaController, command: Ocp1Command) async throws {
    try await super.ensureReadable(by: controller, command: command)
    guard controller.flags.contains(.isLocal) else { throw Ocp1Error.status(.permissionDenied) }
  }
}

/// A class no object of the device has until a test adds one.
private final class LateActuator: SwiftOCADevice.OcaActuator {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), 77)
  }

  @OcaDeviceProperty(propertyID: OcaPropertyID("4.1"), getMethodID: OcaMethodID("4.1"))
  var depth: OcaUint16 = 3
}

/// Hears from the device of the controllers whose connections have gone.
private final class ExpiryDelegate: OcaDeviceEventDelegate {
  private let expired = Mutex([ObjectIdentifier]())

  func onEvent(_ event: OcaEvent, parameters: OcaEventParameters) async {}

  func onControllerExpiry(_ controller: any OcaController) async {
    expired.withLock { $0.append(ObjectIdentifier(controller)) }
  }

  func hasExpired(_ controller: any OcaController) -> Bool {
    expired.withLock { $0.contains(ObjectIdentifier(controller)) }
  }
}

/// The objects the tests share: the process has one device, and its tree only grows.
@OcaDevice
private enum Fixture {
  /// AES's key, which follows the standard class in the ID of every class OCA derives from it.
  static let aes: Int32 = -0x000B5E
  /// PADL's key, where the OCA class ID has PADL's authority.
  static let padl: Int32 = -0x0AE91B
  private(set) static var block: SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaRoot>!
  private(set) static var gain: SwiftOCADevice.OcaGain!
  private(set) static var trimmed: TrimmedGain!
  private(set) static var identify: SwiftOCADevice.OcaIdentificationActuator!
  private(set) static var fixed: FixedLabelGain!
  private(set) static var locked: LockedLabelGain!
  private(set) static var localOnly: LocalOnlyAgent!
  private(set) static var model: NMOSOcaDeviceModel!
  nonisolated static let ids = NMOSOcaResourceIDs(seed: "control-model-tests")

  static func make() async throws {
    guard model == nil else { return }
    _ = try await TestDevice.networkManager()
    let device = OcaDevice.shared
    block = try await SwiftOCADevice.OcaBlock(role: "Channel-\(UUID().uuidString)", deviceDelegate: device)
    gain = try await SwiftOCADevice.OcaGain(role: "Gain", deviceDelegate: device, addToRootBlock: false)
    trimmed = try await TrimmedGain(role: "Gain", deviceDelegate: device, addToRootBlock: false)
    identify = try await SwiftOCADevice.OcaIdentificationActuator(
      role: "Identify.Now", deviceDelegate: device, addToRootBlock: false
    )
    fixed = try await FixedLabelGain(role: "Fixed", deviceDelegate: device, addToRootBlock: false)
    fixed.label = "Factory"
    locked = try await LockedLabelGain(role: "Locked", deviceDelegate: device, addToRootBlock: false)
    locked.label = "Held"
    localOnly = try await LocalOnlyAgent(role: "LocalOnly", deviceDelegate: device, addToRootBlock: false)
    for object in [gain, trimmed, identify, fixed, locked, localOnly] as [SwiftOCADevice.OcaRoot] {
      try await block.add(actionObject: object)
    }
    model = NMOSOcaDeviceModel(device: device, resourceIDs: { ids })
  }
}

final class NMOSOcaDeviceModelTests: XCTestCase {
  private var model: NMOSOcaDeviceModel!
  /// The session the helpers act for: a controller somewhere on the network.
  private var session = NcSession(peer: .ip("192.0.2.10", port: 50000))

  @OcaDevice
  override func setUp() async throws {
    try await Fixture.make()
    model = Fixture.model
    session = NcSession(peer: .ip("192.0.2.10", port: 50000))
  }

  @OcaDevice
  override func tearDown() async throws {
    await model.sessionEnded(session)
  }

  @OcaDevice
  private func get(
    _ oid: NcOid, _ level: UInt16, _ index: UInt16, as session: NcSession? = nil
  ) async -> NcMethodResult {
    await model.invoke(
      oid: oid, methodID: .init(level: 1, index: 1),
      arguments: ["id": NcElementID(level: level, index: index).json], session: session ?? self.session
    )
  }

  @OcaDevice
  private func set(
    _ oid: NcOid, _ level: UInt16, _ index: UInt16, _ value: NMOSJSONValue, as session: NcSession? = nil
  ) async -> NcMethodResult {
    await model.invoke(
      oid: oid, methodID: .init(level: 1, index: 2),
      arguments: ["id": NcElementID(level: level, index: index).json, "value": value],
      session: session ?? self.session
    )
  }

  @OcaDevice
  private func members(of oid: NcOid, recurse: Bool = false) async -> [NMOSJSONValue] {
    await model.invoke(
      oid: oid, methodID: .init(level: 2, index: 1), arguments: ["recurse": .bool(recurse)], session: session
    )
      .value?.arrayValue ?? []
  }

  @OcaDevice
  private func classDescriptor(_ classID: NcClassID, inherited: Bool = false) async throws -> NMOSJSONValue {
    let result = await model.invoke(
      oid: model.classManagerOid, methodID: .init(level: 3, index: 1),
      arguments: ["classId": classID.json, "includeInherited": .bool(inherited)], session: session
    )
    return try XCTUnwrap(result.value, "no class \(classID): \(result.errorMessage ?? "")")
  }

  @OcaDevice
  private func classID(of oid: NcOid) async throws -> NcClassID {
    let result = await get(oid, 1, 1)
    return try XCTUnwrap(result.value.flatMap(NcClassID.init(json:)))
  }

  /// The next notification, or nil if none arrives in time.
  @OcaDevice
  private func next(_ notifications: AsyncStream<NcNotification>) async -> NcNotification? {
    await withTaskGroup(of: NcNotification?.self) { group in
      group.addTask {
        var iterator = notifications.makeAsyncIterator()
        return await iterator.next()
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  // MARK: The tree

  @OcaDevice
  func testTheRootBlockIsOidOneAndHoldsTheManagers() async throws {
    let identity = await [get(1, 1, 2).value, get(1, 1, 4).value, get(1, 1, 5).value]
    XCTAssertEqual(identity, [1, .null, "root"])
    let rootClass = try await classID(of: 1)
    XCTAssertTrue(rootClass.starts(with: NcStandardModel.block))

    let members = await members(of: 1)
    let deviceManager = try XCTUnwrap(members.first { $0["role"] == "DeviceManager" })
    // OCA's device manager is object 1, which MS-05-02 keeps for the root block
    XCTAssertEqual(deviceManager["oid"], .integer(Int64(OcaRootBlockONo)))
    XCTAssertEqual(deviceManager["owner"], 1)
    let managerClass = try XCTUnwrap(deviceManager["classId"].flatMap(NcClassID.init(json:)))
    XCTAssertTrue(managerClass.starts(with: NcStandardModel.deviceManager))

    let classManager = try XCTUnwrap(members.first { $0["role"] == "ClassManager" })
    XCTAssertEqual(classManager["oid"], .integer(Int64(OcaMaximumReservedONo)))
    // OcaClassManager's methods are NcClassManager's own, so it is presented as that class
    XCTAssertEqual(classManager["classId"], NcStandardModel.classManager.json)
    // every other OCA manager is in the root block too
    XCTAssertTrue(members.contains { $0["oid"] == .integer(Int64(OcaNetworkManagerONo)) })
    XCTAssertTrue(members.contains { $0["oid"] == .integer(Int64(Fixture.block.objectNumber)) })
  }

  @OcaDevice
  func testRolesAreUniqueInEachBlockAndHaveNoDots() async throws {
    var blocks: [NcOid] = [1]
    var visited = 0
    while let block = blocks.popLast() {
      let members = await members(of: block)
      let roles = members.compactMap { $0["role"]?.stringValue }
      XCTAssertEqual(roles.count, members.count)
      XCTAssertEqual(Set(roles).count, roles.count, "roles repeat in block \(block): \(roles)")
      XCTAssertFalse(roles.contains { $0.contains(".") || $0.isEmpty }, "\(roles)")
      for member in members {
        visited += 1
        let classID = try XCTUnwrap(member["classId"].flatMap(NcClassID.init(json:)))
        if classID.starts(with: NcStandardModel.block), let oid = member["oid"]?.integerValue {
          blocks.append(NcOid(oid))
        }
      }
    }
    XCTAssertGreaterThan(visited, 5)

    // two objects with one OCA role, and a role with a dot in it
    let roles = await members(of: Fixture.block.objectNumber).compactMap { $0["role"]?.stringValue }
    XCTAssertEqual(
      roles.prefix(6), ["Gain", "Gain_\(Fixture.trimmed.objectNumber)", "Identify_Now", "Fixed", "Locked", "LocalOnly"]
    )
  }

  // MARK: Classes

  @OcaDevice
  func testAnOcaClassIsDerivedFromTheStandardClassItCorrespondsTo() async throws {
    let gain = Fixture.gain.objectNumber
    let aes = Fixture.aes
    let classID = await get(gain, 1, 1)
    // NcWorker, the key of AES whose class it is, then OCA's 1.1.1.5 below its root
    XCTAssertEqual(classID.value, [1, 2, .integer(Int64(aes)), 1, 1, 5])

    let own = try await classDescriptor([1, 2, aes, 1, 1, 5])
    XCTAssertEqual(own["name"], "OcaGain")
    XCTAssertEqual(own["properties"], [NcPropertyDescriptor(
      id: .init(level: 5, index: 1), name: "gain", typeName: "NcFloat32", isReadOnly: false
    ).json])

    // each OCA class of the lineage is a class, at the level after the one above it
    let worker = try await classDescriptor([1, 2, aes, 1])
    XCTAssertEqual(worker["name"], "OcaWorker")
    let levels = worker["properties"]?.arrayValue?.compactMap { $0["id"]?["level"]?.integerValue }
    XCTAssertEqual(Set(levels ?? []), [3])
    let names = worker["properties"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    // what NcObject and NcWorker already say of the object is not said again
    XCTAssertTrue(names.contains("ports"))
    XCTAssertFalse(names.contains("enabled") || names.contains("label") || names.contains("owner"))
    let actuator = try await classDescriptor([1, 2, aes, 1, 1])
    XCTAssertEqual(actuator["name"], "OcaActuator")

    let inherited = try await classDescriptor([1, 2, aes, 1, 1, 5], inherited: true)
    let all = inherited["properties"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    XCTAssertTrue(all.starts(with: ["classId", "oid"]))
    XCTAssertTrue(all.contains("enabled") && all.contains("ports") && all.contains("gain"))
  }

  @OcaDevice
  func testAnOcaProprietaryClassKeepsItsAuthority() async throws {
    let (aes, padl) = (Fixture.aes, Fixture.padl)
    let classID = await get(Fixture.trimmed.objectNumber, 1, 1)
    XCTAssertEqual(classID.value, [1, 2, .integer(Int64(aes)), 1, 1, 5, .integer(Int64(padl)), 1])
    let descriptor = try await classDescriptor([1, 2, aes, 1, 1, 5, padl, 1])
    XCTAssertEqual(descriptor["name"], "TrimmedGain")
    let properties = try XCTUnwrap(descriptor["properties"]?.arrayValue)
    XCTAssertEqual(properties.map { $0["name"] }, ["trim", "routing", "note", "cellX", "cellY"])
    XCTAssertEqual(properties.map { $0["id"] }, (1...5).map { NcElementID(level: 6, index: $0).json })
    // a map is a sequence of entries, and an optional is nullable
    XCTAssertEqual(properties[1]["isSequence"], true)
    XCTAssertEqual(properties[2]["isNullable"], true)
    XCTAssertEqual(properties[2]["isReadOnly"], true)

    XCTAssertEqual(
      TrimmedGain.classID.ncIndices, [1, 1, 5, padl, 1]
    )
  }

  @OcaDevice
  func testAClassAnIDNamesIsDescribedThoughNoClassOfTheObjectStandsForIt() async throws {
    let aes = Fixture.aes
    // OCA's boolean actuator is 1.1.1.1.1, which SwiftOCADevice derives from OcaActuator
    // (1.1.1) without the basic actuator (1.1.1.1) between them
    let toggle = try await SwiftOCADevice.OcaBooleanActuator(
      role: "Toggle", deviceDelegate: OcaDevice.shared, addToRootBlock: false
    )
    try await Fixture.block.add(actionObject: toggle)
    let classID = await get(toggle.objectNumber, 1, 1)
    XCTAssertEqual(classID.value, [1, 2, .integer(Int64(aes)), 1, 1, 1, 1])

    let unstated = try await classDescriptor([1, 2, aes, 1, 1, 1])
    XCTAssertEqual(unstated["name"], "OcaBasicActuator")
    XCTAssertEqual(unstated["properties"], [])
    // a class's level is its depth by its ID, so the actuator's setting is at level 6
    let own = try await classDescriptor([1, 2, aes, 1, 1, 1, 1])
    XCTAssertEqual(own["properties"], [NcPropertyDescriptor(
      id: .init(level: 6, index: 1), name: "setting", typeName: "NcBoolean", isReadOnly: false
    ).json])
    let setting = await get(toggle.objectNumber, 6, 1)
    XCTAssertEqual(setting.value, false)

    XCTAssertEqual(OcaClassID("1.1.1.1.1").classIDs(after: "1.1.1"), ["1.1.1.1"])
    XCTAssertEqual(TrimmedGain.classID.classIDs(after: "1.1.1"), ["1.1.1.5"])
    XCTAssertEqual(TrimmedGain.classID.classIDs(after: "1.1.1.5"), [])
  }

  @OcaDevice
  func testEachManagerIsTheOnlyObjectOfItsClass() async throws {
    let managers = await members(of: 1).filter {
      ($0["classId"].flatMap(NcClassID.init(json:)) ?? []).starts(with: NcStandardModel.manager)
    }
    let classIDs = managers.compactMap { $0["classId"] }
    XCTAssertGreaterThan(managers.count, 3)
    XCTAssertEqual(Set(classIDs).count, classIDs.count, "\(classIDs)")
    // NcManager is only a base: a manager with nothing of its own to present is still
    // a class derived from the standard one, with its role fixed
    XCTAssertFalse(classIDs.contains(NcStandardModel.manager.json))
    let subscriptions = try XCTUnwrap(managers.first { $0["oid"] == .integer(Int64(OcaSubscriptionManagerONo)) })
    let classID = try XCTUnwrap(subscriptions["classId"].flatMap(NcClassID.init(json:)))
    let descriptor = try await classDescriptor(classID)
    XCTAssertEqual(descriptor["name"], "OcaSubscriptionManager")
    XCTAssertEqual(descriptor["fixedRole"], subscriptions["role"])
  }

  @OcaDevice
  func testIdentificationIsTheStandardBeacon() async throws {
    let identify = Fixture.identify.objectNumber
    let classID = try await classID(of: identify)
    XCTAssertTrue(classID.starts(with: NcStandardModel.identBeacon))
    let before = await get(identify, 3, 1)
    XCTAssertEqual(before.value, false)
    let written = await set(identify, 3, 1, true)
    XCTAssertEqual(written.status, .ok)
    XCTAssertTrue(Fixture.identify.active)
    // NcWorker's property is OCA's, under NcWorker's ID
    let enabled = await get(identify, 2, 1)
    XCTAssertEqual(enabled.value, true)
  }

  // MARK: Properties

  @OcaDevice
  func testGetAndSetReachTheOcaProperty() async throws {
    let gain = Fixture.gain.objectNumber
    let written = await set(gain, 5, 1, -6.5)
    XCTAssertEqual(written.status, .ok)
    XCTAssertEqual(Fixture.gain.gain.value, -6.5)
    let read = await get(gain, 5, 1)
    XCTAssertEqual(read.value, -6.5)

    let disabled = await set(gain, 2, 1, false)
    XCTAssertEqual(disabled.status, .ok)
    XCTAssertFalse(Fixture.gain.enabled)
    _ = await set(gain, 2, 1, true)

    let statuses = await [
      set(gain, 5, 1, "loud").status, get(gain, 5, 9).status, set(gain, 5, 9, 1).status,
      // a property declared without a setter
      set(Fixture.trimmed.objectNumber, 6, 3, "x").status,
    ]
    XCTAssertEqual(statuses, [.parameterError, .propertyNotImplemented, .propertyNotImplemented, .readonly])
  }

  @OcaDevice
  func testValuesMS0502CannotDescribeAreReshaped() async throws {
    let trimmed = Fixture.trimmed.objectNumber
    Fixture.trimmed.routing = [1: [OcaPortID(mode: .input, index: 2)]]
    let routing = await get(trimmed, 6, 2)
    XCTAssertEqual(routing.value, [["Key": 1, "Value": [["Mode": 1, "Index": 2]]]])

    // a sequence may hold a key twice and a map cannot, so the first entry for a key is kept
    let written = await set(trimmed, 6, 2, [
      ["Key": 3, "Value": [["Mode": 2, "Index": 4]]],
      ["Key": 3, "Value": [["Mode": 1, "Index": 5]]],
    ])
    XCTAssertEqual(written.status, .ok)
    XCTAssertEqual(Fixture.trimmed.routing, [3: [OcaPortID(mode: .output, index: 4)]])
    let descriptor = try await classDescriptor([1, 2, Fixture.aes, 1, 1, 5, Fixture.padl, 1])
    let routingDescriptor = descriptor["properties"]?.arrayValue?.first { $0["name"] == "routing" }
    XCTAssertEqual(routingDescriptor?["isReadOnly"], false)

    // an optional with no value reads as null rather than failing
    let note = await get(trimmed, 6, 3)
    XCTAssertEqual(note, NcMethodResult(value: .null))
  }

  @OcaDevice
  func testWhetherALabelIsReadIsTheDevicesToDecide() async throws {
    let sealed = try await SealedAgent(role: "Sealed", deviceDelegate: OcaDevice.shared, addToRootBlock: false)
    sealed.label = "Private"
    try await Fixture.block.add(actionObject: sealed)
    // the label is the OCA label, which the device refuses to read but lets be written
    let refused = await get(sealed.objectNumber, 1, 6)
    XCTAssertEqual(refused.status, .unauthorized)
    let written = await set(sealed.objectNumber, 1, 6, "Mine")
    XCTAssertEqual(written.status, .ok)
    XCTAssertEqual(sealed.label, "Mine")
  }

  @OcaDevice
  func testAPropertyWithASetterIsWritableUntilTheDeviceRefuses() async throws {
    let aes = Fixture.aes
    let device = OcaDevice.shared
    let fixed = try await FixedMidpointPan(role: "Pan", deviceDelegate: device, addToRootBlock: false)
    let plain = try await SwiftOCADevice.OcaPanBalance(role: "PlainPan", deviceDelegate: device, addToRootBlock: false)
    try await Fixture.block.add(actionObject: fixed)
    try await Fixture.block.add(actionObject: plain)

    // OCA gives both a setter, so both are described as writable
    let descriptor = try await classDescriptor([1, 2, aes, 1, 1, 6])
    let properties = descriptor["properties"]?.arrayValue ?? []
    XCTAssertEqual(properties.map { $0["name"] }, ["position", "midpointGain"])
    XCTAssertEqual(properties.map { $0["isReadOnly"] }, [false, false])

    // the device refuses one, when it is set
    let refused = await set(fixed.objectNumber, 5, 2, 0.0)
    XCTAssertEqual(refused.status, .readonly)
    let moved = await set(fixed.objectNumber, 5, 1, 0.5)
    XCTAssertEqual(moved.status, .ok)
    XCTAssertEqual(fixed.position.value, 0.5)
    let allowed = await set(plain.objectNumber, 5, 2, 0.0)
    XCTAssertEqual(allowed.status, .ok)
  }

  @OcaDevice
  func testTheRangeOfABoundedPropertyIsARuntimeConstraint() async throws {
    let gain = Fixture.gain.objectNumber
    Fixture.gain.gain = OcaBoundedPropertyValue(value: 0, in: -60...12)
    let constraints = await get(gain, 1, 8)
    XCTAssertEqual(constraints.value, [
      NcPropertyConstraintsNumber(propertyID: .init(level: 5, index: 1), minimum: -60.0, maximum: 12.0).json,
    ])
    // the device holds a value to the range, and says so as MS-05-02 does
    let refused = await set(gain, 5, 1, 13)
    XCTAssertEqual(refused.status, .parameterError)
    let accepted = await set(gain, 5, 1, 12)
    XCTAssertEqual(accepted.status, .ok)

    // a range that is open at one end constrains only the other
    Fixture.gain.gain = OcaBoundedPropertyValue(value: 0, in: -.infinity...12)
    let open = await get(gain, 1, 8)
    XCTAssertEqual(open.value, [
      NcPropertyConstraintsNumber(propertyID: .init(level: 5, index: 1), maximum: 12.0).json,
    ])
    Fixture.gain.gain = OcaBoundedPropertyValue(value: 0, in: -144...20)

    // an object with no bounded property has no constraints
    let none = await get(Fixture.identify.objectNumber, 1, 8)
    XCTAssertEqual(none, NcMethodResult(value: .null))
  }

  @OcaDevice
  func testTheUserLabelIsTheOcaLabelWhereThereIsOne() async throws {
    let gain = Fixture.gain.objectNumber
    let written = await set(gain, 1, 6, "Left")
    XCTAssertEqual(written.status, .ok)
    XCTAssertEqual(Fixture.gain.label, "Left")
    let cleared = await set(gain, 1, 6, .null)
    XCTAssertEqual(cleared.status, .ok)
    XCTAssertEqual(Fixture.gain.label, "")

    // a manager has no label in OCA, so the label store keeps one for it
    let manager = NcOid(OcaNetworkManagerONo)
    let before = await get(manager, 1, 6)
    XCTAssertEqual(before, NcMethodResult(value: .null))
    let named = await set(manager, 1, 6, "Networks")
    XCTAssertEqual(named.status, .ok)
    let after = await get(manager, 1, 6)
    XCTAssertEqual(after.value, "Networks")
    let rejected = await set(manager, 1, 6, 7)
    XCTAssertEqual(rejected.status, .parameterError)
    _ = await set(manager, 1, 6, .null)

    // but an object whose device refuses to change its OCA label keeps it
    let fixed = Fixture.fixed.objectNumber
    let renamed = await set(fixed, 1, 6, "Mine")
    XCTAssertEqual(renamed.status, .unauthorized)
    let factory = await get(fixed, 1, 6)
    XCTAssertEqual(factory.value, "Factory")

    // but a lock is the session's error, and leaves the label as it is
    let locked = Fixture.locked.objectNumber
    let refused = await set(locked, 1, 6, "Mine")
    XCTAssertEqual(refused.status, .locked)
    XCTAssertEqual(Fixture.locked.label, "Held")
    let held = await get(locked, 1, 6)
    XCTAssertEqual(held.value, "Held")
  }

  @OcaDevice
  func testTheDeviceManagerIsTheStandardOne() async throws {
    let oid = NcOid(OcaRootBlockONo)
    let shared = await OcaDevice.shared.deviceManager
    let deviceManager = try XCTUnwrap(shared)
    deviceManager.serialNumber = "MT0001"
    deviceManager.manufacturer = OcaManufacturer(
      name: "PADL", organizationID: OcaOrganizationID((0x0A, 0xE9, 0x1B)), website: "https://padl.com"
    )
    deviceManager.product = OcaProduct(name: "MonitorTwo", modelID: "MT2", revisionLevel: "1.0")

    let values = await [get(oid, 3, 1).value, get(oid, 3, 4).value, get(oid, 3, 2).value, get(oid, 3, 3).value]
    XCTAssertEqual(values, [
      "v1.0.0", "MT0001",
      ["name": "PADL", "organizationId": 0x0AE91B, "website": "https://padl.com"],
      ["name": "MonitorTwo", "key": "MT2", "revisionLevel": "1.0", "brandName": .null,
       "uuid": .null, "description": .null],
    ])
    let state = await get(oid, 3, 8)
    XCTAssertEqual(state.value, ["generic": 1, "deviceSpecificDetails": .null])
    let cause = await get(oid, 3, 9)
    XCTAssertEqual(cause.value, 1)

    let named = await set(oid, 3, 6, "Studio A")
    XCTAssertEqual(named.status, .ok)
    XCTAssertEqual(deviceManager.deviceName, "Studio A")
    let statuses = await [set(oid, 3, 4, "x").status, set(oid, 3, 2, [:]).status, get(oid, 3, 11).status]
    XCTAssertEqual(statuses, [.readonly, .readonly, .propertyNotImplemented])
    let role = await get(oid, 1, 5)
    XCTAssertEqual(role.value, "DeviceManager")
  }

  /// What nmos-testing checks of a device model: every property a class descriptor
  /// lists is of the type the descriptor names, where the device lets it be read.
  @OcaDevice
  func testEveryPropertyReadsAsItsDescriptorSays() async throws {
    Fixture.trimmed.routing = [1: [OcaPortID(mode: .input, index: 2)]]
    let manager = model.classManagerOid
    let allDatatypes = await get(manager, 3, 2)
    let datatypeList = try XCTUnwrap(allDatatypes.value?.arrayValue)
    let datatypes = Dictionary(datatypeList.compactMap { type in type["name"]?.stringValue.map { ($0, type) } },
                               uniquingKeysWith: { first, _ in first })
    XCTAssertEqual(datatypes.count, datatypeList.count, "a datatype is described twice")

    var checked = 0
    let rootClass = try await classID(of: 1)
    for member in await members(of: 1, recurse: true) + [["oid": 1, "classId": rootClass.json]] {
      let oid = try NcOid(XCTUnwrap(member["oid"]?.integerValue))
      let classID = try XCTUnwrap(member["classId"].flatMap(NcClassID.init(json:)))
      let descriptor = try await classDescriptor(classID, inherited: true)
      for property in descriptor["properties"]?.arrayValue ?? [] {
        let id = try XCTUnwrap(property["id"].flatMap(NcElementID.init(json:)))
        let name = "\(descriptor["name"]?.stringValue ?? "?").\(property["name"]?.stringValue ?? "?") of \(oid)"
        let result = await get(oid, id.level, id.index)
        if result.status == .unauthorized { continue }
        XCTAssertEqual(result.status, .ok, "\(name): \(result.errorMessage ?? "")")
        guard let value = result.value else { XCTFail("\(name) has no value"); continue }
        XCTAssertNil(
          Self.mismatch(value, property, in: datatypes), "\(name) = \(value)"
        )
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 100)
  }

  /// Why `value` is not what a property or field descriptor says, nil if it is.
  private static func mismatch(
    _ value: NMOSJSONValue,
    _ descriptor: NMOSJSONValue,
    in datatypes: [String: NMOSJSONValue]
  ) -> String? {
    if value.isNull { return descriptor["isNullable"] == true ? nil : "null" }
    guard let typeName = descriptor["typeName"]?.stringValue else { return nil }
    guard descriptor["isSequence"] == true else { return mismatch(value, typeName, in: datatypes) }
    guard let items = value.arrayValue else { return "not a sequence" }
    return items.lazy.compactMap { mismatch($0, typeName, in: datatypes) }.first
  }

  private static func mismatch(_ value: NMOSJSONValue, _ typeName: String, in datatypes: [String: NMOSJSONValue]) -> String? {
    guard let datatype = datatypes[typeName] else { return "\(typeName) is not described" }
    switch datatype["type"]?.integerValue {
    case 0:
      let matches = switch typeName {
      case "NcBoolean": value.boolValue != nil
      case "NcString": value.stringValue != nil
      case "NcFloat32", "NcFloat64": value.doubleValue != nil
      default: value.integerValue != nil
      }
      return matches ? nil : "not \(typeName)"
    case 1:
      guard let parent = datatype["parentType"]?.stringValue else { return "no parent" }
      guard datatype["isSequence"] == true else { return mismatch(value, parent, in: datatypes) }
      guard let items = value.arrayValue else { return "not a sequence" }
      return items.lazy.compactMap { mismatch($0, parent, in: datatypes) }.first
    case 2:
      guard let object = value.objectValue else { return "not an object" }
      for field in datatype["fields"]?.arrayValue ?? [] {
        guard let name = field["name"]?.stringValue, let member = object[name] else {
          return "field missing"
        }
        if let reason = mismatch(member, field, in: datatypes) { return "\(name): \(reason)" }
      }
      return nil
    default:
      let items = datatype["items"]?.arrayValue?.compactMap { $0["value"]?.integerValue } ?? []
      return value.integerValue.map(items.contains) == true ? nil : "not an item of \(typeName)"
    }
  }

  // MARK: Sessions

  @OcaDevice
  func testASessionIsTheControllerItsPeerIsAndNeverTheBridge() async throws {
    let agent = Fixture.localOnly.objectNumber
    let (aes, padl) = (Fixture.aes, Fixture.padl)
    // what only a local controller may read is presented, and the device refuses it
    let descriptor = try await classDescriptor([1, aes, 2, padl, 9])
    XCTAssertEqual(descriptor["properties"]?.arrayValue?.map { $0["name"] }, ["secret", "setting"])
    let secret = await get(agent, 3, 1)
    XCTAssertEqual(secret.status, .unauthorized)
    XCTAssertNil(secret.value)
    let stolen = await set(agent, 3, 1, "mine")
    XCTAssertTrue(stolen.status.isError)
    XCTAssertEqual(Fixture.localOnly.secret, "hunter2")

    // what only a local controller may write, a session from the network may only read
    let setting = await get(agent, 3, 2)
    XCTAssertEqual(setting.value, "factory")
    let refused = await set(agent, 3, 2, "remote")
    XCTAssertEqual(refused.status, .unauthorized)
    XCTAssertEqual(Fixture.localOnly.setting, "factory")
    for peer in [NcSession.Peer.ip("127.0.0.1", port: 50001), .ip("::1", port: 50002)] as [NcSession.Peer?] + [nil] {
      // an address is never proof of being local, the host's own included
      let other = NcSession(peer: peer)
      let refused = await set(agent, 3, 2, "loopback", as: other)
      XCTAssertEqual(refused.status, .unauthorized)
      await model.sessionEnded(other)
    }
    XCTAssertEqual(Fixture.localOnly.setting, "factory")

    // a session over a socket of the host's own is the local controller it is
    let local = NcSession(peer: .local("/run/ocad/control.socket"))
    let allowed = await set(agent, 3, 2, "local", as: local)
    XCTAssertEqual(allowed.status, .ok)
    XCTAssertEqual(Fixture.localOnly.setting, "local")
    Fixture.localOnly.setting = "factory"
    await model.sessionEnded(local)

    let controller = try XCTUnwrap(model.source.controller(of: session))
    XCTAssertEqual(controller.flags, .supportsLocking)
    XCTAssertEqual(controller.controlProtocol, .ocp2)
    XCTAssertEqual(controller.description, "ncp/tcp/192.0.2.10:50000")
  }

  @OcaDevice
  func testEachSessionIsAControllerOfItsOwn() async throws {
    let gain = Fixture.gain.objectNumber
    let other = NcSession(peer: .ip("192.0.2.20", port: 50000))
    _ = await get(gain, 5, 1)
    _ = await get(gain, 5, 1, as: other)
    let mine = try XCTUnwrap(model.source.controller(of: session))
    let theirs = try XCTUnwrap(model.source.controller(of: other))
    XCTAssertFalse(mine === theirs)
    let listed = await model.source.endpoint.controllers
    XCTAssertTrue(listed.contains { $0 === mine } && listed.contains { $0 === theirs })

    // a lock one session's controller takes binds the other session, and not itself
    let lock = Ocp1Command(targetONo: gain, methodID: OcaMethodID("1.3"))
    let locked = await OcaDevice.shared.handleCommand(lock, from: mine)
    XCTAssertEqual(locked.statusCode, .ok)
    let blocked = await get(gain, 5, 1, as: other)
    XCTAssertEqual(blocked.status, .locked)
    let refused = await set(gain, 5, 1, -3, as: other)
    XCTAssertEqual(refused.status, .locked)
    let allowed = await get(gain, 5, 1)
    XCTAssertEqual(allowed.status, .ok)

    // each hears of the objects it subscribed to, and of no others
    let myEvents = model.notifications(for: session), theirEvents = model.notifications(for: other)
    await model.subscriptionsChanged(to: [gain], session: session)
    await model.subscriptionsChanged(to: [Fixture.trimmed.objectNumber], session: other)
    _ = await set(gain, 5, 1, -42)
    let heard = await next(myEvents)
    XCTAssertEqual(heard?.eventData["value"], -42.0)
    _ = await set(Fixture.trimmed.objectNumber, 6, 1, 4)
    let overheard = await next(theirEvents)
    XCTAssertEqual(overheard?.oid, Fixture.trimmed.objectNumber)

    // the session's end releases its lock, as a controller's disconnecting does
    await model.sessionEnded(session)
    let released = await get(gain, 5, 1, as: other)
    XCTAssertEqual(released.status, .ok)
    await model.sessionEnded(other)
  }

  @OcaDevice
  func testEndingASessionRemovesItsController() async throws {
    let gain = Fixture.gain.objectNumber
    let ending = NcSession(peer: .ip("192.0.2.30", port: 50000))
    let events = model.notifications(for: ending)
    await model.subscriptionsChanged(to: [gain], session: ending)
    let controller = try XCTUnwrap(model.source.controller(of: ending))
    let manager = await OcaDevice.shared.subscriptionManager
    let subscriptionManager = try XCTUnwrap(manager)
    XCTAssertTrue(subscriptionManager.isSubscribed(controller, toEventsFrom: gain))
    let before = await model.source.endpoint.controllers
    XCTAssertTrue(before.contains { $0 === controller })

    await model.sessionEnded(ending)
    let gone = model.source.controller(of: ending)
    XCTAssertNil(gone)
    let after = await model.source.endpoint.controllers
    XCTAssertFalse(after.contains { $0 === controller })
    // its events are over: nothing the device does now reaches it
    Fixture.gain.label = "After \(UUID().uuidString)"
    let last = await next(events)
    XCTAssertNil(last)
    // ending it again, or a session that never did anything, is harmless
    await model.sessionEnded(ending)
    await model.sessionEnded(NcSession(peer: nil))
  }

  @OcaDevice
  func testTheDeviceIsToldASessionsControllerHasGone() async throws {
    let delegate = ExpiryDelegate()
    await OcaDevice.shared.setEventDelegate(delegate)
    let ending = NcSession(peer: .ip("192.0.2.40", port: 50000))
    await model.subscriptionsChanged(to: [Fixture.gain.objectNumber], session: ending)
    let controller = try XCTUnwrap(model.source.controller(of: ending))
    XCTAssertFalse(delegate.hasExpired(controller))

    await model.sessionEnded(ending)
    // the device tells its delegate without making the caller wait
    for _ in 0..<200 where !delegate.hasExpired(controller) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(delegate.hasExpired(controller))
  }

  // MARK: Vectors

  @OcaDevice
  func testDescriptorsAreKeptAndAClassMetLaterIsAdded() async throws {
    let (aes, padl) = (Fixture.aes, Fixture.padl)
    let gain: NcClassID = [1, 2, aes, 1, 1, 5]
    let first = try await classDescriptor(gain, inherited: true)
    let second = try await classDescriptor(gain, inherited: true)
    XCTAssertEqual(first, second)
    let before = await get(model.classManagerOid, 3, 1)
    let again = await get(model.classManagerOid, 3, 1)
    XCTAssertEqual(before, again)

    let late: NcClassID = [1, 2, aes, 1, 1, padl, 77]
    let listed = before.value?.arrayValue ?? []
    XCTAssertFalse(listed.contains { $0["classId"] == late.json })
    let object = try await LateActuator(
      role: "Late-\(UUID().uuidString)", deviceDelegate: OcaDevice.shared, addToRootBlock: false
    )
    try await Fixture.block.add(actionObject: object)

    // the block says it has a new member, and the class is there the next time it is asked for
    let after = await get(model.classManagerOid, 3, 1)
    XCTAssertEqual(after.value?.arrayValue?.count, listed.count + 1)
    XCTAssertTrue(after.value?.arrayValue?.contains { $0["classId"] == late.json } == true)
    let descriptor = try await classDescriptor(late)
    XCTAssertEqual(descriptor["name"], "LateActuator")
    XCTAssertEqual(descriptor["properties"]?.arrayValue?.first?["name"], "depth")
    let classID = try await classID(of: object.objectNumber)
    XCTAssertEqual(classID, late)
    let unchanged = try await classDescriptor(gain, inherited: true)
    XCTAssertEqual(unchanged, first)
  }

  @OcaDevice
  func testTheTreeIsTheDevicesAsItIsNow() async throws {
    let unknown = await get(NcOid(0x7000_0000), 1, 2)
    XCTAssertEqual(unknown.status, .badOid)

    // a block that gains or loses a member is seen to at once
    let added = try await SwiftOCADevice.OcaGain(
      role: "Added-\(UUID().uuidString)", deviceDelegate: OcaDevice.shared, addToRootBlock: false
    )
    let unowned = await get(added.objectNumber, 1, 2)
    XCTAssertEqual(unowned.status, .badOid)
    try await Fixture.block.add(actionObject: added)
    let found = await get(added.objectNumber, 1, 2)
    XCTAssertEqual(found.value, .integer(Int64(added.objectNumber)))
    let members = await model.source.members(of: Fixture.block.objectNumber)
    XCTAssertTrue(members.contains(added.objectNumber))
    try await Fixture.block.delete(actionObject: added)
    let removed = await get(added.objectNumber, 1, 2)
    XCTAssertEqual(removed.status, .badOid)
  }

  @OcaDevice
  func testAVectorIsItsTwoComponents() async throws {
    let trimmed = Fixture.trimmed.objectNumber
    let descriptor = try await classDescriptor([1, 2, Fixture.aes, 1, 1, 5, Fixture.padl, 1])
    let components = descriptor["properties"]?.arrayValue?.suffix(2).map { $0["typeName"] }
    XCTAssertEqual(components, ["NcUint16", "NcUint16"])

    Fixture.trimmed.cellXY = OcaVector2D(x: 3, y: 4)
    let values = await [get(trimmed, 6, 4).value, get(trimmed, 6, 5).value]
    XCTAssertEqual(values, [3, 4])

    // OCA sets the pair, so one component is written with the other as it stands
    let written = await set(trimmed, 6, 5, 9)
    XCTAssertEqual(written.status, .ok)
    XCTAssertEqual(Fixture.trimmed.cellXY.x, 3)
    XCTAssertEqual(Fixture.trimmed.cellXY.y, 9)
    let rejected = await set(trimmed, 6, 4, "left")
    XCTAssertEqual(rejected.status, .parameterError)

    // OCA reports each component's change under its own property ID
    let notifications = model.notifications(for: session)
    await model.subscriptionsChanged(to: [trimmed], session: session)
    Fixture.trimmed.cellXY = OcaVector2D(x: 5, y: 6)
    var changes = [NMOSJSONValue: NMOSJSONValue]()
    for _ in 0..<2 {
      guard let notification = await next(notifications) else { break }
      changes[notification.eventData["propertyId"] ?? .null] = notification.eventData["value"]
    }
    XCTAssertEqual(changes, [
      NcElementID(level: 6, index: 4).json: 5, NcElementID(level: 6, index: 5).json: 6,
    ])
    await model.subscriptionsChanged(to: [], session: session)
  }

  // MARK: Events

  @OcaDevice
  func testAChangeInTheDeviceIsNotifiedToSubscribedObjectsOnly() async throws {
    let gain = Fixture.gain.objectNumber, trimmed = Fixture.trimmed.objectNumber
    let notifications = model.notifications(for: session)
    await model.subscriptionsChanged(to: [gain], session: session)

    // changed by the device itself, as an OCA controller or a front panel would
    Fixture.trimmed.label = "Not subscribed"
    Fixture.gain.label = "From OCA \(UUID().uuidString)"
    let first = await next(notifications)
    XCTAssertEqual(first?.oid, gain)
    XCTAssertEqual(first?.eventID, .propertyChanged)
    XCTAssertEqual(first?.eventData, NcPropertyChangedEventData(
      propertyID: .userLabel, value: .string(Fixture.gain.label)
    ).json)

    // a property of a derived class is notified under the ID it is presented with
    _ = await set(gain, 5, 1, -20)
    let second = await next(notifications)
    XCTAssertEqual(second?.eventData["propertyId"], NcElementID(level: 5, index: 1).json)
    XCTAssertEqual(second?.eventData["value"], -20.0)

    // and once only, though the bridge and the object both report it
    await model.subscriptionsChanged(to: [trimmed], session: session)
    _ = await set(gain, 5, 1, -30)
    _ = await set(trimmed, 6, 1, 3)
    let third = await next(notifications)
    XCTAssertEqual(third?.oid, trimmed)
    await model.subscriptionsChanged(to: [], session: session)
  }

  @OcaDevice
  func testALabelTheStoreKeepsIsNotifiedToo() async throws {
    let manager = NcOid(OcaNetworkManagerONo)
    let notifications = model.notifications(for: session)
    await model.subscriptionsChanged(to: [manager], session: session)
    _ = await set(manager, 1, 6, "Notified")
    let notification = await next(notifications)
    XCTAssertEqual(notification?.oid, manager)
    XCTAssertEqual(notification?.eventData["value"], "Notified")
    _ = await set(manager, 1, 6, .null)
    await model.subscriptionsChanged(to: [], session: session)
  }

  @OcaDevice
  func testObjectsPointToTheResourcesTheyStandFor() async throws {
    let root = await get(1, 1, 7)
    XCTAssertEqual(root.value, [NcTouchpoint(resourceType: "device", id: Fixture.ids.device).json])
    let deviceManager = await get(NcOid(OcaRootBlockONo), 1, 7)
    XCTAssertEqual(deviceManager.value, [NcTouchpoint(resourceType: "node", id: Fixture.ids.node).json])
    let gain = await get(Fixture.gain.objectNumber, 1, 7)
    XCTAssertEqual(gain.value, .null)
  }

  @OcaDevice
  func testAModelThatGoesAwayTakesItsEndpointFromTheDevice() async throws {
    var model: NMOSOcaDeviceModel? = NMOSOcaDeviceModel(device: OcaDevice.shared)
    // walking the tree gives the device the endpoint and the bridge's controller
    let members = await model?.source.members(of: 1)
    XCTAssertFalse(members?.isEmpty ?? true)
    let endpoint = try XCTUnwrap(model?.source.endpoint)
    model = nil

    // the device lets go of it a moment later; then it can be given it again
    var removed = false
    for _ in 0..<100 where !removed {
      removed = (try? await OcaDevice.shared.add(endpoint: endpoint)) != nil
      if !removed { try await Task.sleep(for: .milliseconds(10)) }
    }
    XCTAssertTrue(removed)
    try await OcaDevice.shared.remove(endpoint: endpoint)
  }
}

/// The datatypes worked out from Swift types.
final class NMOSOcaDatatypesTests: XCTestCase {
  private enum Colour: UInt8, Codable, CaseIterable { case red = 1, green = 3 }
  private struct Flags: OptionSet, Codable { let rawValue: UInt16 }
  private struct Record: Codable {
    var name: String
    var colour: Colour
    var flags: Flags
    var id: OcaPropertyID
    var blob: OcaBlob
    var level: Float?
    var ports: [OcaPortID]
  }

  @OcaDevice
  func testAStructIsDescribedByItsFields() async throws {
    let datatypes = NMOSOcaDatatypes()
    let schema = try datatypes.schema(of: Record.self)
    XCTAssertEqual(schema, .structure("Record"))
    let descriptors = Dictionary(uniqueKeysWithValues: datatypes.descriptors.map { ($0.name, $0) })
    XCTAssertEqual(descriptors["Record"]?.kind, .struct(fields: [
      .init(name: "Name", typeName: "NcString"),
      .init(name: "Colour", typeName: "Colour"),
      .init(name: "Flags", typeName: "NcUint16"),
      .init(name: "Id", typeName: "OcaElementID"),
      .init(name: "Blob", typeName: "OcaBlob"),
      .init(name: "Level", typeName: "NcFloat32", isNullable: true),
      .init(name: "Ports", typeName: "OcaPortID", isSequence: true),
    ], parentType: nil))
    XCTAssertEqual(descriptors["Colour"]?.kind, .enum(items: [
      .init(name: "red", value: 1), .init(name: "green", value: 3),
    ]))
    XCTAssertEqual(descriptors["OcaElementID"]?.kind, .typedef(parentType: "NcUint16", isSequence: true))
    XCTAssertEqual(descriptors["OcaBlob"]?.kind, .typedef(parentType: "NcString", isSequence: false))
    XCTAssertNotNil(descriptors["OcaPortID"])
  }

  @OcaDevice
  func testValuesConvertBetweenOcp2AndStandardForms() async throws {
    let datatypes = NMOSOcaDatatypes()
    let record = Record(
      name: "A", colour: .green, flags: Flags(rawValue: 5), id: "3.1",
      blob: OcaBlob([1, 2, 3]), level: -.infinity, ports: [OcaPortID(mode: .output, index: 7)]
    )
    let oca = try NMOSJSONValue(ocp2: Ocp2Encoder().encodeValue(record))
    let standard = try datatypes.standard(from: oca, as: datatypes.schema(of: Record.self))
    XCTAssertEqual(standard, [
      "Name": "A", "Colour": 3, "Flags": 5, "Id": [3, 1], "Blob": "AQID",
      // JSON has no infinity; the type's most negative number stands for it
      "Level": .number(-Double(Float.greatestFiniteMagnitude)),
      "Ports": [["Mode": 2, "Index": 7]],
    ])
    let back = try datatypes.oca(from: standard, as: .structure("Record"))
    let decoded = try Ocp2Decoder().decodeValue(Record.self, from: back.ocp2)
    XCTAssertEqual(decoded.name, "A")
    XCTAssertEqual(decoded.colour, .green)
    XCTAssertEqual(decoded.ports.first?.index, 7)

    XCTAssertThrowsError(try datatypes.standard(from: ["Name": 1], as: .structure("Record")))
    XCTAssertThrowsError(try datatypes.oca(from: "x", as: .integer("NcInt32")))
  }

  @OcaDevice
  func testAMapIsASequenceOfEntriesAndAClassIDIsNumbers() async throws {
    let datatypes = NMOSOcaDatatypes()
    let map = try datatypes.schema(of: [OcaUint16: [OcaPortID]].self)
    let reference = try datatypes.reference(to: map)
    XCTAssertTrue(reference.isSequence)
    XCTAssertTrue(reference.typeName.hasPrefix("OcaMapItem_"))
    let oca = try NMOSJSONValue(ocp2: Ocp2Encoder().encodeValue([OcaUint16(4): [OcaPortID(mode: .input, index: 1)]]))
    XCTAssertEqual(
      try datatypes.standard(from: oca, as: map), [["Key": 4, "Value": [["Mode": 1, "Index": 1]]]]
    )

    let proprietary = OcaClassID(parent: "1.1.1.5", authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), 1)
    let classID = try NMOSJSONValue(ocp2: Ocp2Encoder().encodeValue(proprietary))
    XCTAssertEqual(
      try datatypes.standard(from: classID, as: datatypes.schema(of: OcaClassID.self)),
      [1, 1, 1, 5, 0xFFFF, 0x0A, 0xE91B, 1]
    )
  }

  @OcaDevice
  func testWhatCannotBeDescribedIsRefused() async throws {
    let datatypes = NMOSOcaDatatypes()
    XCTAssertThrowsError(try datatypes.reference(to: datatypes.schema(of: [[String?]].self)))
    XCTAssertThrowsError(try datatypes.reference(to: .sequence(.optional(.string))))
    // sequences of sequences are given a name for the inner one
    let nested = try datatypes.reference(to: datatypes.schema(of: [[UInt32]].self))
    XCTAssertEqual(nested, NMOSOcaTypeReference(typeName: "NcUint32List", isSequence: true))
  }
}
