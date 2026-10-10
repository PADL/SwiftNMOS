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
@testable import NMOSOCABridge
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
import Synchronization
import XCTest

private extension NMOSOcaObservedProperties {
  /// The classes declared, and those an object is one of.
  var classIDs: Set<OcaClassID> { Set(entries.map(\.classID)) }

  func classIDs(of object: SwiftOCADevice.OcaRoot) -> Set<OcaClassID> {
    Set(entries.filter { $0.matches(object) }.map(\.classID))
  }
}

final class NMOSOcaObservedObjectTests: XCTestCase {
  @OcaDevice
  private var properties: NMOSOcaObservedProperties { NMOSOcaAdaptations.standard.observedProperties }

  @OcaDevice
  private func observe(_ object: SwiftOCADevice.OcaRoot) async -> NMOSOcaObservedObject {
    await NMOSOcaObservedObject(object, observing: properties, by: NMOSOcaObserver(device: OcaDevice.shared))
  }

  @OcaDevice
  func testATransportApplicationsCountersAreNotAChangeButItsEndpointsAre() async throws {
    let application = try await TestDevice.makeApplication("Observed")
    let observed = await observe(application)
    XCTAssertFalse(observed.isChange("3.12"))
    XCTAssertFalse(observed.isChange("2.6"))
    XCTAssertTrue(observed.isChange("3.10"))
  }

  /// The device tells the bridge's controller of a change, as it would any controller.
  @OcaDevice
  func testAChangeAfterTheObjectIsObservedIsHeardOf() async throws {
    let application = try await TestDevice.makeApplication("Observed")
    let observed = await observe(application)
    application.label = "Renamed"
    let heard = Mutex<OcaPropertyID?>(nil)
    await observed.observe { id in
      heard.withLock { $0 = id }
      return false
    }
    XCTAssertEqual(heard.withLock { $0 }, "2.1")
  }

  /// An adaptation the bridge does not know might read a subclass's property.
  @OcaDevice
  func testASubclassPropertyNobodyDeclaresIsAChange() async throws {
    let application = try await SwiftOCADevice.Aes67OcaMediaTransportApplication(
      role: TestDevice.role("AES67"), deviceDelegate: OcaDevice.shared
    )
    let observed = await observe(application)
    XCTAssertTrue(observed.isChange("4.1"))
    XCTAssertFalse(observed.isChange("3.12"))
  }

  @OcaDevice
  func testAnObjectOfAClassNobodyDeclaresIsObservedForEveryChange() async throws {
    let gain = try await SwiftOCADevice.OcaGain(role: TestDevice.role("Gain"), deviceDelegate: OcaDevice.shared)
    let observed = await observe(gain)
    XCTAssertTrue(observed.isChange("4.1"))
    XCTAssertTrue(observed.isChange("1.5"))
  }

  /// Every property declared as read is one its class has, so a mistyped ID cannot leave
  /// a property unobserved; and the objects here are of every class declared.
  @OcaDevice
  func testEveryDeclaredPropertyIsOneItsClassHas() async throws {
    let device = OcaDevice.shared
    let manager = await device.deviceManager
    let deviceManager = try XCTUnwrap(manager)
    let objects: [SwiftOCADevice.OcaRoot] = try await [
      TestDevice.networkManager(),
      deviceManager,
      TestDevice.makeApplication("Declared"),
      SwiftOCADevice.DanteOcaMediaTransportApplication(role: TestDevice.role("Dante"), deviceDelegate: device),
      SwiftOCADevice.OcaNetworkInterface(role: TestDevice.role("Interface"), deviceDelegate: device),
      SwiftOCADevice.OcaMediaClock3(role: TestDevice.role("Clock"), deviceDelegate: device),
      SwiftOCADevice.OcaTimeSource(role: TestDevice.role("TimeSource"), deviceDelegate: device),
      SwiftOCADevice.OcaMediaTransportSessionAgent(role: TestDevice.role("Agent"), deviceDelegate: device),
    ]
    var covered = Set<OcaClassID>()
    for object in objects {
      covered.formUnion(properties.classIDs(of: object))
      let declared = properties.properties(of: object).properties
      let has = Set(object.deviceClassDescriptors.flatMap(\.properties).flatMap { [$0.propertyID, $0.yPropertyID] }
        .compactMap(\.self))
      XCTAssertEqual(declared.subtracting(has), [], "\(type(of: object)) has no such property")
    }
    XCTAssertEqual(properties.classIDs.subtracting(covered), [], "no object here is of these classes")
  }
}
