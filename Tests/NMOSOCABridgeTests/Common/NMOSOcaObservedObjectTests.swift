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
import SwiftOCADevice
import Synchronization
import XCTest

final class NMOSOcaObservedObjectTests: XCTestCase {
  @OcaDevice
  private var properties: NMOSOcaObservedProperties { NMOSOcaAdaptations.standard.observedProperties }

  @OcaDevice
  func testATransportApplicationsCountersAreNotAChangeButItsEndpointsAre() async throws {
    let application = try await TestDevice.makeApplication("Observed")
    let observed = NMOSOcaObservedObject(application, observing: properties)

    application.endpointCounterSets = [1: OcaCounterSet()]
    XCTAssertFalse(observed.isChange("3.12"))
    application.counterSet = OcaCounterSet()
    XCTAssertFalse(observed.isChange("2.6"))

    application.insert(endpoint: OcaMediaStreamEndpoint(idInternal: 1, direction: .input), status: .init(state: .ready))
    XCTAssertTrue(observed.isChange("3.10"))
  }

  /// A change made between observing an object and its first signal is not missed.
  @OcaDevice
  func testAChangeAfterTheObjectIsObservedIsOne() async throws {
    let application = try await TestDevice.makeApplication("Observed")
    let observed = NMOSOcaObservedObject(application, observing: properties)
    application.label = "Renamed"
    XCTAssertTrue(observed.isChange("2.1"))
  }

  /// An adaptation the bridge does not know might read a subclass's property.
  @OcaDevice
  func testASubclassPropertyNobodyDeclaresIsAChange() async throws {
    let application = try await SwiftOCADevice.Aes67OcaMediaTransportApplication(
      role: TestDevice.role("AES67"), deviceDelegate: OcaDevice.shared
    )
    let observed = NMOSOcaObservedObject(application, observing: properties)
    // its first signal is the value it has
    XCTAssertFalse(observed.isChange("4.1"))
    application.streamSourceRegistryONo = 4096
    XCTAssertTrue(observed.isChange("4.1"))
    XCTAssertFalse(observed.isChange("3.12"))
  }

  @OcaDevice
  func testAnObjectOfAClassNobodyDeclaresIsObservedForEveryChange() async throws {
    let gain = try await SwiftOCADevice.OcaGain(role: TestDevice.role("Gain"), deviceDelegate: OcaDevice.shared)
    let observed = NMOSOcaObservedObject(gain, observing: properties)
    // each property's first signal is the value it has
    XCTAssertFalse(observed.isChange("4.1"))
    XCTAssertFalse(observed.isChange("1.5"))
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
      let declared = Set(properties.getters(for: object).getters.keys)
      let properties = try await signalledProperties(of: object)
      XCTAssertEqual(declared.subtracting(properties), [], "\(type(of: object)) has no such property")
    }
    XCTAssertEqual(properties.classIDs.subtracting(covered), [], "no object here is of these classes")
  }

  /// The properties an object has: each signals its value when the object is observed.
  @OcaDevice
  private func signalledProperties(of object: SwiftOCADevice.OcaRoot) async throws -> Set<OcaPropertyID> {
    let signalled = Mutex(Set<OcaPropertyID>())
    let task = Task { @OcaDevice in
      for try await id in object.propertyChanges { _ = signalled.withLock { $0.insert(id) } }
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    return signalled.withLock { $0 }
  }
}
