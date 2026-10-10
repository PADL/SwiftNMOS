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
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
import XCTest

/// An agent with methods of its own, among them ones that fail, and one the device
/// refuses to every controller on the network.
@OcaDeviceClass
private final class Calculator: SwiftOCADevice.OcaAgent {
  override class var classID: OcaClassID {
    // not under a vendor's authority, so that its methods are described
    OcaClassID(parent: super.classID, 0x7F0B)
  }

  @OcaDeviceProperty(propertyID: OcaPropertyID("3.1"), getMethodID: OcaMethodID("3.5"))
  var depth: OcaUint16 = 3

  @OcaDeviceMethod("3.1", name: "GetSum", access: .read, parameterNames: ["A", "B"], resultNames: ["Sum"])
  func getSum(_ a: OcaInt32, _ b: OcaInt32, from controller: any OcaController) -> OcaInt32 {
    a &+ b
  }

  @OcaDeviceMethod("3.2", name: "GetUnfinished", access: .read)
  func getUnfinished(from controller: any OcaController) throws -> OcaBoolean {
    throw Ocp1Error.status(.notImplemented)
  }

  @OcaDeviceMethod("3.3", name: "GetSecret", access: .read)
  func getSecret(from controller: any OcaController) throws -> OcaString {
    throw Ocp1Error.status(.permissionDenied)
  }

  @OcaDeviceMethod("3.4", name: "ResetEverything", access: .write)
  func resetEverything(from controller: any OcaController) {}

  // the getter of `depth`, declared as a method too
  @OcaDeviceMethod("3.5", name: "GetDepth", access: .read)
  func getDepth(from controller: any OcaController) -> OcaUint16 {
    depth
  }

  override func ensureWritable(by controller: any OcaController, command: Ocp1Command) async throws {
    try await super.ensureWritable(by: controller, command: command)
    guard command.methodID != OcaMethodID("3.4") || controller.flags.contains(.isLocal) else {
      throw Ocp1Error.status(.permissionDenied)
    }
  }
}

/// A class of PADL's, whose methods may be called but are not described.
@OcaDeviceClass
private final class VendorDial: SwiftOCADevice.OcaAgent {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), 12)
  }

  @OcaDeviceProperty(propertyID: OcaPropertyID("3.1"), getMethodID: OcaMethodID("3.2"))
  var position: OcaUint16 = 7

  @OcaDeviceMethod("3.1", name: "GetTurns", access: .read, resultNames: ["Turns"])
  func getTurns(from controller: any OcaController) -> OcaUint16 {
    3
  }
}

/// What only a hidden property of `Vault` holds.
private struct VaultCombination: Codable, Equatable, Sendable {
  var first: OcaUint16
  var second: OcaUint16
}

/// An agent with a hidden property and a hidden method, which the device still answers.
@OcaDeviceClass
private class Vault: SwiftOCADevice.OcaAgent {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, 0x7F0C)
  }

  @OcaDeviceProperty(propertyID: OcaPropertyID("3.1"), getMethodID: OcaMethodID("3.1"))
  var door: OcaUint16 = 1

  @OcaDeviceProperty(
    propertyID: OcaPropertyID("3.2"),
    getMethodID: OcaMethodID("3.2"),
    setMethodID: OcaMethodID("3.3"),
    hidden: true
  )
  var combination = VaultCombination(first: 4, second: 2)

  @OcaDeviceMethod("3.4", name: "GetOpenings", access: .read, hidden: true)
  func getOpenings(from controller: any OcaController) -> OcaUint16 {
    9
  }
}

/// A class derived from `Vault`, which inherits its hidden elements.
@OcaDeviceClass
private final class BankVault: Vault {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, 1)
  }

  @OcaDeviceProperty(propertyID: OcaPropertyID("4.1"), getMethodID: OcaMethodID("4.1"))
  var alarm: OcaUint16 = 0
}

/// The objects the tests share, in a block of their own.
@OcaDevice
private enum MethodFixture {
  /// AES's and PADL's keys, which follow the standard class in a derived class's ID.
  static let aes: Int32 = -0x000B5E
  static let padl: Int32 = -0x0AE91B
  private(set) static var block: SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaRoot>!
  private(set) static var gain: SwiftOCADevice.OcaGain!
  private(set) static var calculator: Calculator!
  private(set) static var dial: VendorDial!
  private(set) static var vault: Vault!
  private(set) static var bankVault: BankVault!
  private(set) static var model: NMOSOcaDeviceModel!

  static func make() async throws {
    guard model == nil else { return }
    _ = try await TestDevice.networkManager()
    let device = OcaDevice.shared
    block = try await SwiftOCADevice.OcaBlock(role: "Methods-\(UUID().uuidString)", deviceDelegate: device)
    gain = try await SwiftOCADevice.OcaGain(role: "Gain", deviceDelegate: device, addToRootBlock: false)
    gain.ports = [OcaPort(owner: gain.objectNumber, id: OcaPortID(direction: .input, index: 1), role: "In 1")]
    calculator = try await Calculator(role: "Calculator", deviceDelegate: device, addToRootBlock: false)
    try await block.add(actionObject: gain)
    dial = try await VendorDial(role: "Dial", deviceDelegate: device, addToRootBlock: false)
    try await block.add(actionObject: calculator)
    try await block.add(actionObject: dial)
    // in a block of their own, so the first block's members stay as they are
    let vaults = try await SwiftOCADevice.OcaBlock(role: "Vaults-\(UUID().uuidString)", deviceDelegate: device)
    vault = try await Vault(role: "Vault", deviceDelegate: device, addToRootBlock: false)
    bankVault = try await BankVault(role: "BankVault", deviceDelegate: device, addToRootBlock: false)
    try await vaults.add(actionObject: vault)
    try await vaults.add(actionObject: bankVault)
    model = NMOSOcaDeviceModel(device: device)
  }
}

final class NMOSOcaMethodTests: XCTestCase {
  private var model: NMOSOcaDeviceModel!
  private let session = NcSession(peer: .ip("192.0.2.11", port: 50001))

  @OcaDevice
  override func setUp() async throws {
    try await MethodFixture.make()
    model = MethodFixture.model
  }

  @OcaDevice
  override func tearDown() async throws {
    await model.sessionEnded(session)
  }

  @OcaDevice
  private func oid(of object: SwiftOCADevice.OcaRoot) -> NcOid {
    NMOSOcaControlMapping.oid(of: object.objectNumber)
  }

  @OcaDevice
  private func invoke(
    _ object: SwiftOCADevice.OcaRoot,
    _ level: UInt16,
    _ index: UInt16,
    _ arguments: [String: NMOSJSONValue] = [:]
  ) async -> NcMethodResult {
    await model.handleCommand(
      NcCommand(oid: oid(of: object), methodID: .init(level: level, index: index), arguments: arguments),
      session: session
    )
  }

  /// The class an object is presented as, with what it inherits.
  @OcaDevice
  private func classDescriptor(of object: SwiftOCADevice.OcaRoot) async throws -> NMOSJSONValue {
    let classID = await invoke(object, 1, 1, ["id": NcElementID(level: 1, index: 1).json]).value
    let result = await model.handleCommand(
      NcCommand(oid: model.classManagerOid, methodID: .init(level: 3, index: 1), arguments: ["classId": try XCTUnwrap(classID), "includeInherited": true]),
      session: session
    )
    return try XCTUnwrap(result.value, result.errorMessage ?? "")
  }

  @OcaDevice
  private func datatype(_ name: String) async throws -> NMOSJSONValue {
    let result = await model.handleCommand(
      NcCommand(oid: model.classManagerOid, methodID: .init(level: 3, index: 2), arguments: ["name": .string(name), "includeInherited": false]),
      session: session
    )
    return try XCTUnwrap(result.value, result.errorMessage ?? "")
  }

  @OcaDevice
  private func methods(of object: SwiftOCADevice.OcaRoot) async throws -> [String: NMOSJSONValue] {
    let methods = try await classDescriptor(of: object)["methods"]?.arrayValue ?? []
    return Dictionary(methods.compactMap { method in method["name"]?.stringValue.map { ($0, method) } }) { first, _ in
      first
    }
  }

  // MARK: Description

  @OcaDevice
  func testAWorkerMethodIsPresentedAtItsMappedLevel() async throws {
    // OcaWorker is OCA level 2 under NcWorker at level 2: its GetPortName, 2.6, is 3m6
    let methods = try await methods(of: MethodFixture.gain)
    let method = try XCTUnwrap(methods["GetPortName"])
    XCTAssertEqual(method["id"], NcElementID(level: 3, index: 6).json)
    XCTAssertEqual(method["isDeprecated"], false)
    let parameters = try XCTUnwrap(method["parameters"]?.arrayValue)
    XCTAssertEqual(parameters.map { $0["name"] }, ["PortID"])
    XCTAssertEqual(parameters.first?["typeName"], "OcaPortID")
    XCTAssertEqual(parameters.first?["isSequence"], false)
    XCTAssertEqual(parameters.first?["isNullable"], false)

    // its result derives from NcMethodResult, the name being its one field, `value`
    let resultName = try XCTUnwrap(method["resultDatatype"]?.stringValue)
    XCTAssertEqual(resultName, "OcaWorkerGetPortNameResult")
    let result = try await datatype(resultName)
    XCTAssertEqual(result["parentType"], "NcMethodResult")
    XCTAssertEqual(result["fields"]?.arrayValue?.map { $0["name"] }, ["value"])
    XCTAssertEqual(result["fields"]?.arrayValue?.first?["typeName"], "NcString")
  }

  @OcaDevice
  func testAMethodWithSeveralResultsHasAFieldForEach() async throws {
    let methods = try await methods(of: MethodFixture.gain)
    let method = try XCTUnwrap(methods["GetPath"])
    XCTAssertEqual(method["id"], NcElementID(level: 3, index: 13).json)
    XCTAssertEqual(method["parameters"]?.arrayValue, [])
    let result = try await datatype(XCTUnwrap(method["resultDatatype"]?.stringValue))
    XCTAssertEqual(result["parentType"], "NcMethodResult")
    XCTAssertEqual(result["fields"]?.arrayValue?.map { $0["name"] }, ["RolePath", "ONoPath"])
  }

  @OcaDevice
  func testAMethodOfABlockIsPresentedBelowTheStandardBlock() async throws {
    // OcaBlock is OCA level 3 under NcBlock at level 2: GetActionObjectsRecursive, 3.6, is 4m6
    let methods = try await methods(of: MethodFixture.block)
    let method = try XCTUnwrap(methods["GetActionObjectsRecursive"])
    XCTAssertEqual(method["id"], NcElementID(level: 4, index: 6).json)
    XCTAssertEqual(method["parameters"]?.arrayValue, [])
    // NcBlock's own methods are the standard ones
    XCTAssertEqual(methods["GetMemberDescriptors"]?["id"], NcElementID(level: 2, index: 1).json)

    let members = await invoke(MethodFixture.block, 4, 6)
    XCTAssertEqual(members.status, .ok, members.errorMessage ?? "")
    XCTAssertEqual(members.value?.arrayValue?.count, 3)
  }

  @OcaDevice
  func testAMethodOfAClassOfItsOwnIsPresented() async throws {
    let methods = try await methods(of: MethodFixture.calculator)
    // OcaAgent has no standard counterpart, so the calculator's class is at NcObject's level + 2
    let sum = try XCTUnwrap(methods["GetSum"])
    XCTAssertEqual(sum["id"], NcElementID(level: 3, index: 1).json)
    XCTAssertEqual(sum["parameters"]?.arrayValue?.map { $0["name"] }, ["A", "B"])
    XCTAssertEqual(sum["parameters"]?.arrayValue?.map { $0["typeName"] }, ["NcInt32", "NcInt32"])
  }

  @OcaDevice
  func testAVendorMethodIsDescribedAndCallable() async throws {
    let descriptor = try await classDescriptor(of: MethodFixture.dial)
    let methods = descriptor["methods"]?.arrayValue ?? []
    XCTAssertTrue(methods.contains { $0["name"] == "GetTurns" })
    let properties = descriptor["properties"]?.arrayValue ?? []
    XCTAssertTrue(properties.contains { $0["name"] == "position" })

    let turns = await invoke(MethodFixture.dial, 3, 1)
    XCTAssertEqual(turns.status, .ok, turns.errorMessage ?? "")
    XCTAssertEqual(turns.value, 3)
  }

  @OcaDevice
  func testAPropertyAccessorIsNotAlsoAMethod() async throws {
    let descriptor = try await classDescriptor(of: MethodFixture.calculator)
    let methods = descriptor["methods"]?.arrayValue ?? []
    XCTAssertFalse(methods.contains { $0["name"] == "GetDepth" })
    XCTAssertFalse(methods.contains { $0["id"] == NcElementID(level: 3, index: 5).json })
    let properties = descriptor["properties"]?.arrayValue ?? []
    XCTAssertTrue(properties.contains { $0["name"] == "depth" })
    // and no method is listed twice
    let ids = methods.compactMap(\.["id"])
    XCTAssertEqual(Set(ids).count, ids.count)
  }

  @OcaDevice
  func testAMethodTheDeviceRefusesToTheNetworkIsPresentedAndRefusedWhenCalled() async throws {
    let methods = try await methods(of: MethodFixture.calculator)
    XCTAssertNotNil(methods["ResetEverything"])
    let result = await invoke(MethodFixture.calculator, 3, 4)
    XCTAssertEqual(result.status, .unauthorized)
  }

  @OcaDevice
  func testSetResetKeyIsNotPresented() async throws {
    let manager = await OcaDevice.shared.deviceManager
    let deviceManager = try XCTUnwrap(manager)
    let methods = try await methods(of: deviceManager)
    XCTAssertNil(methods["SetResetKey"])
    // the device manager's described methods are, at NcDeviceManager's level + 2
    XCTAssertEqual(methods["ClearResetCause"]?["id"], NcElementID(level: 5, index: 16).json)
  }

  @OcaDevice
  func testHiddenElementsAreNotDescribed() async throws {
    for object in [MethodFixture.vault!, MethodFixture.bankVault!] {
      let descriptor = try await classDescriptor(of: object)
      let properties = descriptor["properties"]?.arrayValue ?? []
      XCTAssertTrue(properties.contains { $0["name"] == "door" })
      XCTAssertFalse(properties.contains { $0["name"] == "combination" })
      XCTAssertFalse(properties.contains { $0["id"] == NcElementID(level: 3, index: 2).json })
      let methods = descriptor["methods"]?.arrayValue ?? []
      XCTAssertFalse(methods.contains { $0["name"] == "GetOpenings" })
      XCTAssertFalse(methods.contains { $0["id"] == NcElementID(level: 3, index: 4).json })
    }
    // nor in any class or datatype the class manager lists
    let manager = await model.handleCommand(
      NcCommand(oid: model.classManagerOid, methodID: .init(level: 1, index: 1), arguments: ["id": NcElementID(level: 3, index: 1).json]),
      session: session
    )
    let elements = try XCTUnwrap(manager.value?.arrayValue).flatMap { descriptor in
      (descriptor["properties"]?.arrayValue ?? []) + (descriptor["methods"]?.arrayValue ?? [])
    }
    XCTAssertTrue(elements.contains { $0["name"] == "alarm" })
    XCTAssertFalse(elements.contains { $0["name"] == "combination" || $0["name"] == "GetOpenings" })
    let datatypes = await model.handleCommand(
      NcCommand(oid: model.classManagerOid, methodID: .init(level: 1, index: 1), arguments: ["id": NcElementID(level: 3, index: 2).json]),
      session: session
    )
    let names = try XCTUnwrap(datatypes.value?.arrayValue).compactMap { $0["name"]?.stringValue }
    XCTAssertFalse(names.contains("VaultCombination"))
    XCTAssertFalse(names.contains { $0.contains("GetOpenings") })
    let combination = await model.handleCommand(
      NcCommand(oid: model.classManagerOid, methodID: .init(level: 3, index: 2), arguments: ["name": "VaultCombination", "includeInherited": false]),
      session: session
    )
    XCTAssertEqual(combination.status, .parameterError)
  }

  // MARK: Invocation

  @OcaDevice
  func testHiddenElementsCanStillBeUsed() async throws {
    let id = NcElementID(level: 3, index: 2).json
    let combination = await invoke(MethodFixture.bankVault, 1, 1, ["id": id])
    XCTAssertEqual(combination.status, .ok, combination.errorMessage ?? "")
    XCTAssertEqual(combination.value, ["First": 4, "Second": 2])
    let set = await invoke(MethodFixture.vault, 1, 2, ["id": id, "value": ["First": 7, "Second": 1]])
    XCTAssertEqual(set.status, .ok, set.errorMessage ?? "")
    XCTAssertEqual(MethodFixture.vault.combination, VaultCombination(first: 7, second: 1))
    let openings = await invoke(MethodFixture.bankVault, 3, 4)
    XCTAssertEqual(openings.status, .ok, openings.errorMessage ?? "")
    XCTAssertEqual(openings.value, 9)
  }

  @OcaDevice
  func testAWorkerMethodRoundTripsThroughTheDevice() async throws {
    let portID: NMOSJSONValue = ["Direction": 1, "Index": 1]
    let name = await invoke(MethodFixture.gain, 3, 6, ["PortID": portID])
    XCTAssertEqual(name, NcMethodResult(value: "In 1"))

    let renamed = await invoke(MethodFixture.gain, 3, 7, ["ID": portID, "Name": "Input One"])
    XCTAssertEqual(renamed.status, .ok, renamed.errorMessage ?? "")
    XCTAssertEqual(MethodFixture.gain.ports.first?.role, "Input One")
    let after = await invoke(MethodFixture.gain, 3, 6, ["PortID": portID])
    XCTAssertEqual(after.value, "Input One")
    MethodFixture.gain.ports = [OcaPort(
      owner: MethodFixture.gain.objectNumber, id: OcaPortID(direction: .input, index: 1), role: "In 1"
    )]
  }

  @OcaDevice
  func testSeveralResultsAreFieldsOfTheResult() async throws {
    let path = await invoke(MethodFixture.gain, 3, 13)
    XCTAssertEqual(path.status, .ok, path.errorMessage ?? "")
    XCTAssertNil(path.value)
    XCTAssertEqual(path.fields?["RolePath"]?.arrayValue?.last, "Gain")
    XCTAssertEqual(path.fields?["ONoPath"]?.arrayValue?.last, .integer(Int64(MethodFixture.gain.objectNumber)))
  }

  @OcaDevice
  func testArgumentsAreConvertedAndChecked() async throws {
    let sum = await invoke(MethodFixture.calculator, 3, 1, ["A": 40, "B": 2])
    XCTAssertEqual(sum, NcMethodResult(value: 42))
    let missing = await invoke(MethodFixture.calculator, 3, 1, ["A": 40])
    XCTAssertEqual(missing.status, .parameterError)
    let mistyped = await invoke(MethodFixture.calculator, 3, 1, ["A": 40, "B": "two"])
    XCTAssertEqual(mistyped.status, .parameterError)
  }

  @OcaDevice
  func testTheDevicesStatusIsTheMethodsStatus() async throws {
    let unfinished = await invoke(MethodFixture.calculator, 3, 2)
    XCTAssertEqual(unfinished.status, .methodNotImplemented)
    let secret = await invoke(MethodFixture.calculator, 3, 3)
    XCTAssertEqual(secret.status, .unauthorized)
    // no method of the class has this index
    let unknown = await invoke(MethodFixture.calculator, 3, 99)
    XCTAssertEqual(unknown.status, .methodNotImplemented)
  }

  @OcaDevice
  func testALockedObjectRefusesAMethodThatWrites() async throws {
    let other = NcSession(peer: .ip("192.0.2.12", port: 50002))
    _ = await model.handleCommand(
      NcCommand(oid: oid(of: MethodFixture.gain), methodID: .init(level: 1, index: 1), arguments: ["id": NcElementID(level: 1, index: 6).json]),
      session: other
    )
    let controller = try XCTUnwrap(model.source.controller(of: other))
    let lock = Ocp1Command(targetONo: MethodFixture.gain.objectNumber, methodID: OcaMethodID("1.3"))
    _ = await OcaDevice.shared.handleCommand(lock, from: controller)
    defer { Task { @OcaDevice in await model.sessionEnded(other) } }

    let portID: NMOSJSONValue = ["Direction": 1, "Index": 1]
    let renamed = await invoke(MethodFixture.gain, 3, 7, ["ID": portID, "Name": "Locked out"])
    XCTAssertEqual(renamed.status, .locked)
  }

  @OcaDevice
  func testTheStandardMethodsStillAnswer() async throws {
    let label = await invoke(MethodFixture.gain, 1, 1, ["id": NcElementID(level: 1, index: 6).json])
    XCTAssertEqual(label.status, .ok)
    let set = await invoke(MethodFixture.gain, 1, 2, ["id": NcElementID(level: 1, index: 6).json, "value": "Trim"])
    XCTAssertEqual(set.status, .ok)
    let members = await invoke(MethodFixture.block, 2, 1, ["recurse": false])
    XCTAssertEqual(members.value?.arrayValue?.count, 3)
  }

  // MARK: Collisions

  /// Every class SwiftOCADevice registers under the standard class IDs, found by
  /// following the IDs down from OcaRoot through the classes that are registered.
  @OcaDevice
  private func registeredClasses() -> [SwiftOCADevice.OcaRoot.Type] {
    var found = [SwiftOCADevice.OcaRoot.Type]()
    var pending = [OcaClassID("1")]
    while let classID = pending.popLast() {
      guard let type = try? OcaDeviceClassRegistry.shared.match(classID: classID), type.classID == classID else {
        continue
      }
      found.append(type)
      pending += (1...40).map { OcaClassID(parent: classID, OcaUint16($0)) }
    }
    return found
  }

  @OcaDevice
  func testNoMethodOfARegisteredClassTakesAStandardMethodsID() async throws {
    let types = registeredClasses()
    XCTAssertGreaterThan(types.count, 50)
    var checked = 0
    for type in types {
      var lineage = [SwiftOCADevice.OcaRoot.Type]()
      var next: AnyClass? = type
      while let current = next as? SwiftOCADevice.OcaRoot.Type {
        lineage.append(current)
        next = _getSuperclass(current)
      }
      // the deepest class of the lineage that has a standard counterpart
      let anchors = lineage.lazy.compactMap { type in NMOSOcaControlMapping.anchors.first { $0.oca == type.classID } }
      let anchor = try XCTUnwrap(anchors.first)
      let standard = NcStandardModel.methodIDs(of: anchor.nc)
      for method in type.deviceMethods where method.methodID.defLevel > 1 {
        let definer = try XCTUnwrap(lineage.first { $0.classID.defLevel == method.methodID.defLevel })
        let id = NcElementID(
          level: definer.classID.ncLevel(under: anchor.nc),
          index: method.methodID.methodIndex
        )
        XCTAssertGreaterThan(id.level, anchor.nc.ncLevel, "\(type).\(method.name)")
        XCTAssertFalse(standard.contains(id), "\(type).\(method.name) is presented as \(id)")
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 100)
  }
}
