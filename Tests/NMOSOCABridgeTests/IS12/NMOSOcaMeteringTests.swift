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

/// A level meter as a vendor might make one: a clip indication of its own, which only the
/// device sets, and a setting a controller may change.
private final class ClippingMeter: SwiftOCADevice.OcaLevelSensor {
  override class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), 12)
  }

  @OcaDeviceProperty(propertyID: OcaPropertyID("5.1"), getMethodID: OcaMethodID("5.1"))
  var clip = false

  @OcaDeviceProperty(
    propertyID: OcaPropertyID("5.2"),
    getMethodID: OcaMethodID("5.2"),
    setMethodID: OcaMethodID("5.3")
  )
  var linked = false
}

@OcaDevice
private enum MeteringFixture {
  private(set) static var block: SwiftOCADevice.OcaBlock<SwiftOCADevice.OcaRoot>!
  private(set) static var meter: ClippingMeter!
  private(set) static var temperature: SwiftOCADevice.OcaTemperatureSensor!
  private(set) static var application: SwiftOCADevice.OcaMediaTransportApplication!
  private(set) static var model: NMOSOcaDeviceModel!

  static func make() async throws {
    guard model == nil else { return }
    _ = try await TestDevice.networkManager()
    let device = OcaDevice.shared
    block = try await SwiftOCADevice.OcaBlock(role: "Metering-\(UUID().uuidString)", deviceDelegate: device)
    meter = try await ClippingMeter(role: "Meter", deviceDelegate: device, addToRootBlock: false)
    temperature = try await SwiftOCADevice.OcaTemperatureSensor(
      role: "Temperature", deviceDelegate: device, addToRootBlock: false
    )
    application = try await SwiftOCADevice.OcaMediaTransportApplication(
      role: "Transport", deviceDelegate: device, addToRootBlock: false
    )
    for object in [meter, temperature, application] as [SwiftOCADevice.OcaRoot] {
      try await block.add(actionObject: object)
    }
    model = NMOSOcaDeviceModel(device: device)
  }
}

/// Metering and counters may be read, and polled, and their changes are notified.
final class NMOSOcaMeteringTests: XCTestCase {
  private var model: NMOSOcaDeviceModel!
  private let session = NcSession(peer: .ip("192.0.2.12", port: 50002))

  @OcaDevice
  override func setUp() async throws {
    try await MeteringFixture.make()
    model = MeteringFixture.model
  }

  @OcaDevice
  override func tearDown() async throws {
    await model.sessionEnded(session)
  }

  @OcaDevice
  private func invoke(
    _ object: SwiftOCADevice.OcaRoot, _ id: NcElementID, _ arguments: [String: NMOSJSONValue] = [:]
  ) async -> NcMethodResult {
    await model.invoke(oid: NcOid(object.objectNumber), methodID: id, arguments: arguments, session: session)
  }

  @OcaDevice
  private func get(_ object: SwiftOCADevice.OcaRoot, _ id: NcElementID) async -> NcMethodResult {
    await invoke(object, .init(level: 1, index: 1), ["id": id.json])
  }

  /// The properties or methods of the object's class and the classes above it, by name.
  @OcaDevice
  private func elements(_ kind: String, of object: SwiftOCADevice.OcaRoot) async throws -> [String: NcElementID] {
    let classIDResult = await get(object, .init(level: 1, index: 1))
    let classID = try XCTUnwrap(classIDResult.value)
    let result = await model.invoke(
      oid: model.classManagerOid, methodID: .init(level: 3, index: 1),
      arguments: ["classId": classID, "includeInherited": true], session: session
    )
    let elements = try XCTUnwrap(result.value?[kind]?.arrayValue, result.errorMessage ?? "")
    return Dictionary(elements.compactMap { element in
      guard let name = element["name"]?.stringValue, let id = element["id"].flatMap(NcElementID.init(json:)) else {
        return nil
      }
      return (name, id)
    }) { first, _ in first }
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

  @OcaDevice
  func testALevelSensorsReadingCanBeReadAndPolled() async throws {
    let meter = MeteringFixture.meter!
    try await meter.update(reading: -12)
    let methods = try await elements("methods", of: meter)
    let getReading = try XCTUnwrap(methods["GetReading"])
    let reading = await invoke(meter, getReading)
    XCTAssertEqual(reading.status, .ok)
    XCTAssertTrue(reading.fields?.values.contains(-12.0) == true, "\(reading)")
    let properties = try await elements("properties", of: meter)
    XCTAssertNotNil(properties["clip"])
    XCTAssertNotNil(properties["linked"])
  }

  @OcaDevice
  func testAMetersClipIsNotifiedButItsPrivateReadingIsNot() async throws {
    let meter = MeteringFixture.meter!
    let properties = try await elements("properties", of: meter)
    let notifications = model.notifications(for: session)
    await model.subscriptionsChanged(to: [NcOid(meter.objectNumber)], session: session)

    // OcaLevelSensor's reading is no property, so its 4.1 events reach no session
    for step in 0..<100 {
      try await meter.update(reading: -Float(step % 60), alwaysNotifySubscribers: true)
    }
    meter.clip.toggle()
    let first = await next(notifications)
    XCTAssertEqual(first?.eventData["propertyId"], properties["clip"]?.json)
    await model.subscriptionsChanged(to: [], session: session)
  }

  @OcaDevice
  func testAGenericSensorsReadingIsNotified() async throws {
    let sensor = MeteringFixture.temperature!
    let properties = try await elements("properties", of: sensor)
    let readingID = try XCTUnwrap(properties["reading"])
    sensor.reading = OcaBoundedPropertyValue(value: 21.5, in: sensor.reading.range)
    let read = await get(sensor, readingID)
    XCTAssertEqual(read.value, 21.5)

    let notifications = model.notifications(for: session)
    await model.subscriptionsChanged(to: [NcOid(sensor.objectNumber)], session: session)
    sensor.reading = OcaBoundedPropertyValue(value: 22.5, in: sensor.reading.range)
    let first = await next(notifications)
    XCTAssertEqual(first?.eventData["propertyId"], readingID.json)
    XCTAssertEqual(first?.eventData["value"], 22.5)
    await model.subscriptionsChanged(to: [], session: session)
  }

  @OcaDevice
  func testCountersAreReadAndNotified() async throws {
    let application = MeteringFixture.application!
    let properties = try await elements("properties", of: application)
    let counters = try XCTUnwrap(properties["endpointCounterSets"])
    XCTAssertNotNil(properties["counterSet"])
    let methods = try await elements("methods", of: application)
    XCTAssertNotNil(methods["GetEndpointCounter"])
    XCTAssertNotNil(methods["ResetCounters"])
    let read = await get(application, counters)
    XCTAssertEqual(read.status, .ok)

    let notifications = model.notifications(for: session)
    await model.subscriptionsChanged(to: [NcOid(application.objectNumber)], session: session)
    let counter = OcaCounter(id: 1, value: 1, initialValue: 0, role: "Packets", notifiers: [])
    application.endpointCounterSets[1] = OcaCounterSet(counter: [counter])
    let first = await next(notifications)
    XCTAssertEqual(first?.eventData["propertyId"], counters.json)
    await model.subscriptionsChanged(to: [], session: session)
  }

  @OcaDevice
  func testASessionsControllerIsSubscribedWhileTheSessionIs() async throws {
    let meter = MeteringFixture.meter!
    await model.subscriptionsChanged(to: [NcOid(meter.objectNumber)], session: session)
    let controller = try XCTUnwrap(model.source.controller(of: session))
    let manager = await OcaDevice.shared.subscriptionManager
    let subscriptionManager = try XCTUnwrap(manager)
    XCTAssertTrue(subscriptionManager.isSubscribed(controller, toEventsFrom: meter.objectNumber))
    await model.subscriptionsChanged(to: [], session: session)
    XCTAssertFalse(subscriptionManager.isSubscribed(controller, toEventsFrom: meter.objectNumber))
  }
}
