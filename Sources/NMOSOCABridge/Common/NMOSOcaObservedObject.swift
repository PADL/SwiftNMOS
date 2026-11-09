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
import Logging
import SwiftOCA
import SwiftOCADevice

/// The properties the bridge reads of each class, a change to any of which has it
/// describe the device again.
public struct NMOSOcaObservedProperties: Sendable {
  struct Entry: Sendable {
    let classID: OcaClassID
    /// Whether an object is of the Swift class, as several may share one class ID.
    let matches: @Sendable (SwiftOCADevice.OcaRoot) -> Bool
    let properties: Set<OcaPropertyID>
  }

  let entries: [Entry]

  public static let empty = NMOSOcaObservedProperties(entries: [])

  /// The properties of `T` that are read; of only those objects `matching` says, if given.
  public static func of<T: SwiftOCADevice.OcaRoot>(
    _: T.Type,
    where matching: @escaping @Sendable (T) -> Bool = { _ in true },
    _ properties: Set<OcaPropertyID>
  ) -> NMOSOcaObservedProperties {
    NMOSOcaObservedProperties(entries: [Entry(
      classID: T.classID, matches: { ($0 as? T).map(matching) ?? false }, properties: properties
    )])
  }

  public static func + (lhs: NMOSOcaObservedProperties, rhs: NMOSOcaObservedProperties) -> NMOSOcaObservedProperties {
    NMOSOcaObservedProperties(entries: lhs.entries + rhs.entries)
  }

  /// What is read of the object, and the highest level of a class declared for it; none
  /// and zero for an object of a class nobody declares.
  func properties(of object: SwiftOCADevice.OcaRoot) -> (properties: Set<OcaPropertyID>, level: OcaUint16) {
    let matching = entries.filter { $0.matches(object) }
    // properties above the deepest class declared are a subclass's
    return (matching.reduce(into: []) { $0.formUnion($1.properties) }, matching.map(\.classID.defLevel).max() ?? 0)
  }
}

/// The bridge's own controller to the device, which hears of changes to the objects it
/// watches as any controller does: subscribed to their PropertyChanged events through
/// the subscription manager, so the device tells it of a change, and only of a change.
/// Its endpoint is the one the device knows the bridge's controllers by, the IS-12
/// sessions' included.
@OcaDevice
final class NMOSOcaObserver {
  private let device: OcaDevice
  private let logger: Logger
  let endpoint = NMOSOcaControlEndpoint()
  /// Giving the device the endpoint, which every controller added waits for.
  private var registration: Task<Void, Never>?
  private var controller: NMOSOcaControlController?
  private var watchers = [OcaONo: [Int: AsyncStream<OcaPropertyID>.Continuation]]()
  private var lastWatcher = 0

  nonisolated init(device: OcaDevice, logger: Logger = Logger(label: "com.padl.NMOSOCABridge")) {
    self.device = device
    self.logger = logger
  }

  /// The device holds the endpoint, and through it every subscription of its controllers;
  /// they go with it.
  deinit {
    guard registration != nil else { return }
    let device = device, endpoint = endpoint
    Task { @OcaDevice in try? await device.remove(endpoint: endpoint) }
  }

  /// Makes the controller one of the device's, through the endpoint.
  func add(_ controller: NMOSOcaControlController) async {
    if let registration {
      await registration.value
    } else {
      let registration = Task { @OcaDevice [device, endpoint, logger] in
        do { try await device.add(endpoint: endpoint) } catch {
          logger.error("not receiving events: the device refused the NMOS control endpoint: \(error)")
        }
      }
      self.registration = registration
      await registration.value
    }
    endpoint.add(controller)
  }

  func remove(_ controller: NMOSOcaControlController) {
    endpoint.remove(controller)
  }

  /// The object's property changes from now on, until the stream is let go of.
  func changes(for object: SwiftOCADevice.OcaRoot) async -> AsyncStream<OcaPropertyID> {
    let controller = await controller()
    let objectNumber = object.objectNumber
    let (stream, continuation) = AsyncStream<OcaPropertyID>.makeStream()
    if watchers[objectNumber, default: [:]].isEmpty {
      try? await device.subscriptionManager?.addSubscription(Self.subscription(objectNumber), for: controller)
    }
    lastWatcher += 1
    let watcher = lastWatcher
    watchers[objectNumber, default: [:]][watcher] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { @OcaDevice in await self?.stopWatching(watcher, of: objectNumber) }
    }
    return stream
  }

  private func stopWatching(_ watcher: Int, of objectNumber: OcaONo) async {
    watchers[objectNumber]?[watcher] = nil
    guard watchers[objectNumber]?.isEmpty == true, let controller else { return }
    watchers[objectNumber] = nil
    await device.subscriptionManager?.removeSubscription(Self.subscription(objectNumber), for: controller)
  }

  private func changed(_ property: OcaPropertyID, of objectNumber: OcaONo) {
    for continuation in watchers[objectNumber]?.values ?? [:].values { continuation.yield(property) }
  }

  private func controller() async -> NMOSOcaControlController {
    if let controller { return controller }
    let controller = NMOSOcaControlController(description: "nmos/bridge", flags: []) {
      [weak self] objectNumber, property in
      await self?.changed(property, of: objectNumber)
    }
    self.controller = controller
    await add(controller)
    return controller
  }

  private static func subscription(_ objectNumber: OcaONo) -> OcaSubscriptionManagerSubscription {
    .subscription2(OcaSubscription2(
      event: OcaEvent(emitterONo: objectNumber, eventID: OcaPropertyChangedEventID),
      notificationDeliveryMode: .normal,
      destinationInformation: OcaNetworkAddress()
    ))
  }
}

@OcaDevice
final class NMOSOcaObservedObject {
  let object: SwiftOCADevice.OcaRoot
  /// The properties the bridge reads.
  private let properties: Set<OcaPropertyID>
  /// Properties above this level are a subclass's, which may be read by an adaptation
  /// this knows nothing of, so a change to one counts.
  private let knownLevel: OcaUint16
  /// Kept while the object is watched, as it is what the device tells of a change.
  private let observer: NMOSOcaObserver
  private let changes: AsyncStream<OcaPropertyID>

  /// The object is watched from here, so a change made after this is not missed:
  /// whoever observes the object describes the device once more after making this.
  init(_ object: SwiftOCADevice.OcaRoot, observing properties: NMOSOcaObservedProperties, by observer: NMOSOcaObserver) async {
    self.object = object
    (self.properties, knownLevel) = properties.properties(of: object)
    self.observer = observer
    changes = await observer.changes(for: object)
  }

  /// Whether a changed property is one the bridge reads.
  func isChange(_ id: OcaPropertyID) -> Bool {
    properties.contains(id) || id.defLevel > knownLevel
  }

  /// Calls `changed` for each change the bridge would see, until it answers false, when
  /// this returns true, or the watching ends, when it returns false.
  @discardableResult
  func observe(_ changed: @OcaDevice (OcaPropertyID) async -> Bool) async -> Bool {
    for await id in changes where isChange(id) {
      guard await changed(id) else { return true }
    }
    return false
  }

  /// Observes the objects together until `changed` answers false for one, which says the
  /// set of objects may have changed. One that goes is simply heard from no more;
  /// whatever removed it says so itself.
  static func observe(
    _ objects: [NMOSOcaObservedObject],
    _ changed: @escaping @Sendable @OcaDevice (NMOSOcaObservedObject, OcaPropertyID) async -> Bool
  ) async {
    await withTaskGroup(of: Bool.self) { group in
      for object in objects {
        group.addTask { await object.observe { id in await changed(object, id) } }
      }
      for await setChanged in group where setChanged { break }
      group.cancelAll()
    }
  }
}
