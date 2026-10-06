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

@testable import NMOSOCABridge
import SwiftOCA
import SwiftOCAClassManager
import SwiftOCADevice
import XCTest

/// The class manager seen by an OCA controller, over a connection of its own to the
/// test device, with a gain on it.
final class OcaClassManagerTests: XCTestCase {
  private struct Harness {
    let connection: OcaLocalConnection
    let endpointTask: Task<Void, Never>
    let classManager: SwiftOCAClassManager.OcaClassManager

    func tearDown() async {
      try? await connection.disconnect()
      endpointTask.cancel()
    }
  }

  private func makeHarness() async throws -> Harness {
    _ = try await TestDevice.networkManager()
    let device = OcaDevice.shared
    _ = try await SwiftOCADevice.OcaGain(role: TestDevice.role("Gain"), deviceDelegate: device)
    _ = try await NMOSOCABridge.OcaClassManager.shared(on: device)
    let endpoint = try await OcaLocalDeviceEndpoint(device: device)
    let endpointTask = Task { do { try await endpoint.run() } catch {} }
    // as a controller does, once: a second registration is refused
    try? await SwiftOCAClassManager.OcaClassManager.register()
    let connection = await OcaLocalConnection(endpoint)
    try await connection.connect()
    let classManager: SwiftOCAClassManager.OcaClassManager = try await connection.resolve(
      object: OcaObjectIdentification(
        oNo: SwiftOCAClassManager.OcaClassManager.objectNumber,
        classIdentification: SwiftOCAClassManager.OcaClassManager.classIdentification
      )
    )
    return Harness(connection: connection, endpointTask: endpointTask, classManager: classManager)
  }

  func testAClassIsDescribedWithItsOwnElementsOrItsAncestorsToo() async throws {
    let h = try await makeHarness()
    defer { Task { await h.tearDown() } }

    let gain = try await h.classManager.getControlClass(
      classID: SwiftOCADevice.OcaGain.classID, includeInherited: false
    )
    XCTAssertEqual(gain.classID, SwiftOCADevice.OcaGain.classID)
    XCTAssertEqual(gain.name, "OcaGain")
    let property = try XCTUnwrap(gain.properties.first { $0.propertyID == OcaPropertyID(defLevel: 4, propertyIndex: 1) })
    XCTAssertEqual(property.name, "gain")
    XCTAssertFalse(property.isReadOnly)
    // its own elements only: nothing of OcaRoot's or OcaWorker's
    XCTAssertTrue(gain.properties.allSatisfy { $0.propertyID.defLevel == 4 })

    let inherited = try await h.classManager.getControlClass(
      classID: SwiftOCADevice.OcaGain.classID, includeInherited: true
    )
    // OcaWorker's label, which a controller can set
    let label = try XCTUnwrap(inherited.properties.first { $0.name == "label" })
    XCTAssertEqual(label.propertyID.defLevel, 2)
    XCTAssertFalse(label.isReadOnly)
    XCTAssertGreaterThan(inherited.properties.count, gain.properties.count)
  }

  func testEveryClassOfTheDevicesObjectsIsListed() async throws {
    let h = try await makeHarness()
    defer { Task { await h.tearDown() } }

    let classes = try await h.classManager.getControlClasses()
    let ids = Set(classes.map(\.classID))
    XCTAssertTrue(ids.contains(SwiftOCADevice.OcaGain.classID))
    XCTAssertTrue(ids.contains(SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaRoot>.classID))
    XCTAssertTrue(ids.contains(SwiftOCAClassManager.OcaClassManager.classID))
    // the class manager describes its own methods
    let own = try XCTUnwrap(classes.first { $0.classID == SwiftOCAClassManager.OcaClassManager.classID })
    let method = try XCTUnwrap(own.methods.first { $0.name == "GetControlClass" })
    XCTAssertEqual(method.parameters.map(\.name), ["ClassID", "IncludeInherited"])
    XCTAssertEqual(ids.count, classes.count, "each class once")
  }

  func testAClassNoObjectIsOfIsAParameterError() async throws {
    let h = try await makeHarness()
    defer { Task { await h.tearDown() } }

    do {
      _ = try await h.classManager.getControlClass(classID: OcaClassID("1.1.1.99"), includeInherited: false)
      XCTFail("no object is of the class")
    } catch let Ocp1Error.status(status) {
      XCTAssertEqual(status, .parameterError)
    }
  }
}
