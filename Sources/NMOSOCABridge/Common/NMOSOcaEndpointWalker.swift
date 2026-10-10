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
import SwiftOCA
import SwiftOCADevice

/// A stream endpoint of a media transport application: what the bridge presents as an
/// NMOS sender (with its source and flow) or receiver.
public struct NMOSOcaEndpoint: Sendable {
  public let application: SwiftOCADevice.OcaMediaTransportApplication
  public let endpoint: OcaMediaStreamEndpoint

  public init(application: SwiftOCADevice.OcaMediaTransportApplication, endpoint: OcaMediaStreamEndpoint) {
    self.application = application
    self.endpoint = endpoint
  }

  /// The endpoint with the ID as the application has it now; nil once it has gone.
  @OcaDevice
  public init?(application: SwiftOCADevice.OcaMediaTransportApplication, id: OcaMediaStreamEndpointID) {
    guard let endpoint = try? application.endpoint(id) else { return nil }
    self.init(application: application, endpoint: endpoint)
  }

  /// The endpoint as the application has it now, for reading back after a change.
  @OcaDevice
  public var refreshed: NMOSOcaEndpoint {
    NMOSOcaEndpoint(application: application, id: endpoint.idInternal) ?? self
  }

  /// An output endpoint sends to the network, so it is an NMOS sender.
  public var isSender: Bool { endpoint.direction == .output }

  public var kind: NMOSResourceKind { isSender ? .sender : .receiver }

  public func id(_ kind: NMOSResourceKind, in ids: NMOSOcaResourceIDs) -> NMOSID {
    ids.id(kind, application: application.objectNumber, endpoint: endpoint.idInternal)
  }
}

/// Finds the device's media transport applications, network interfaces and stream
/// endpoints through its network manager, and observes them as they change. It reads
/// only AES70 connection management objects, so it serves any transport.
@OcaDevice
public final class NMOSOcaEndpointWalker: Sendable {
  private let device: OcaDevice
  private let adaptations: NMOSOcaAdaptations
  /// The controller the walker hears of changes as, which the bridge's other parts share.
  let observer: NMOSOcaObserver

  /// `adaptations` are those whose reads the consumer makes, which are observed too.
  public nonisolated init(device: OcaDevice = .shared, adaptations: NMOSOcaAdaptations = .standard) {
    self.device = device
    self.adaptations = adaptations
    observer = NMOSOcaObserver(device: device)
  }

  public var networkManager: SwiftOCADevice.OcaNetworkManager? {
    get async { await device.resolve(objectNumber: OcaNetworkManagerONo) }
  }

  public var applications: [SwiftOCADevice.OcaMediaTransportApplication] {
    get async {
      await networkManager?.networkApplications.compactMap { $0 as? SwiftOCADevice.OcaMediaTransportApplication } ?? []
    }
  }

  public var networkInterfaces: [SwiftOCADevice.OcaNetworkInterface] {
    get async { await networkManager?.networkInterfaces ?? [] }
  }

  public var endpoints: [NMOSOcaEndpoint] {
    get async {
      await applications.flatMap { application in
        application.endpoints.map { NMOSOcaEndpoint(application: application, endpoint: $0) }
      }
    }
  }

  static let observedProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaNetworkManager.self, [
    .init(defLevel: 3, propertyIndex: 5), // networkInterfaces
    .init(defLevel: 3, propertyIndex: 6), // networkApplications
  ]) + .of(SwiftOCADevice.OcaMediaTransportApplication.self, [
    .init(defLevel: 3, propertyIndex: 10), // endpoints
  ])

  /// Yields whenever something the bridge reads of the network manager, an application
  /// or a network interface changes, and once at the start. Counters and status, which a
  /// transport reports continually, are not among them, nor is a property set again to
  /// the value it has. Changes that arrive together are reported once; the consumer
  /// re-reads what it needs. Ends when the consumer stops iterating.
  public nonisolated func changes() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { @OcaDevice in await self.observe(continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private var observedObjects: [SwiftOCADevice.OcaRoot] {
    get async {
      let manager: [SwiftOCADevice.OcaRoot] = await networkManager.map { [$0] } ?? []
      return await manager + applications + networkInterfaces
    }
  }

  private func observe(_ continuation: AsyncStream<Void>.Continuation) async {
    while !Task.isCancelled {
      let objects = await observedObjects
      guard !objects.isEmpty else {
        // a device without a network manager has nothing to observe: a device makes its
        // manager before NMOS starts, and NMOS stops before the manager goes
        continuation.yield()
        await Self.untilCancelled()
        break
      }
      // each object is watched before the consumer is told to read it all
      let observed = await watch(objects)
      continuation.yield()
      // only the network manager's lists of applications and interfaces change the set
      await NMOSOcaObservedObject.observe(observed) { object in
        continuation.yield()
        return !(object.object is SwiftOCADevice.OcaNetworkManager)
      }
    }
    continuation.finish()
  }

  /// Yields whenever something the walker observes changes or something read of `objects`
  /// does, and once at the start. `objects` is asked again at each change the walker
  /// reports, and its objects are observed afresh when they are not those it gave before.
  nonisolated func changes(
    observing objects: @escaping @Sendable @OcaDevice () async -> [SwiftOCADevice.OcaRoot]
  ) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { @OcaDevice in
        await self.observe(objects, continuation)
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func observe(
    _ objects: @escaping @Sendable @OcaDevice () async -> [SwiftOCADevice.OcaRoot],
    _ continuation: AsyncStream<Void>.Continuation
  ) async {
    while !Task.isCancelled {
      let current = await objects()
      let observedNumbers = current.map(\.objectNumber)
      // each object is watched before the consumer is told to read it all
      let observed = await watch(current)
      continuation.yield()
      await NMOSOcaObservedObject.observe(observed, alongside: {
        for await _ in self.changes() {
          continuation.yield()
          if await objects().map(\.objectNumber) != observedNumbers { return }
        }
      }) { _ in
        continuation.yield()
        return true
      }
    }
  }

  private func watch(_ objects: [SwiftOCADevice.OcaRoot]) async -> [NMOSOcaObservedObject] {
    let properties = adaptations.observedProperties
    var observed = [NMOSOcaObservedObject]()
    for object in objects {
      await observed.append(NMOSOcaObservedObject(object, observing: properties, by: observer))
    }
    return observed
  }

  private static func untilCancelled() async {
    let (stream, continuation) = AsyncStream.makeStream(of: Never.self)
    await withTaskCancellationHandler {
      for await _ in stream {}
    } onCancel: {
      continuation.finish()
    }
  }
}
