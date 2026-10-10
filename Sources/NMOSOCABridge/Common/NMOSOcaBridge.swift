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
import NMOS
import SwiftOCADevice
import Synchronization

/// What the host knows about itself that its OCA object model does not say.
public struct NMOSOcaHost: Sendable, Hashable {
  /// Unique to the physical device and permanent; every resource ID derives from it.
  public let seed: String
  public let hostname: String?
  /// Where the HTTP server serving the NMOS APIs can be reached, preferably by address.
  public let endpoints: [NMOSNodeResource.Endpoint]
  /// The network interfaces senders and receivers can be bound to.
  public let interfaces: [NMOSNodeResource.Interface]

  public init(
    seed: String,
    hostname: String? = nil,
    endpoints: [NMOSNodeResource.Endpoint],
    interfaces: [NMOSNodeResource.Interface] = []
  ) {
    self.seed = seed
    self.hostname = hostname
    self.endpoints = endpoints
    self.interfaces = interfaces
  }
}

/// A sender or receiver as the bridge last described it: the endpoint it stands for, and
/// the adaptation that presents it.
struct NMOSOcaDescribedEndpoint {
  struct Key: Hashable {
    let kind: NMOSResourceKind
    let id: NMOSID
  }

  let endpoint: NMOSOcaEndpoint
  let adaptation: any NMOSOcaTransportAdaptation
}

/// Describes an OCA device as NMOS resources and keeps the description current, and
/// serves the device's connections (IS-05) and objects (IS-12) from the same description.
/// The device is read through its standard AES70 objects only, so the same bridge serves
/// any SwiftOCADevice device.
@OcaDevice
public final class NMOSOcaBridge: Sendable {
  public typealias HostProvider = @Sendable () async -> NMOSOcaHost

  let device: OcaDevice
  private let store: NMOSResourceStore
  private let logger: Logger
  private let labels: any NMOSOcaLabelStore
  let walker: NMOSOcaEndpointWalker
  let adaptations: NMOSOcaAdaptations
  let controls: [NMOSControl]
  private let host: HostProvider
  /// The describe in progress, which the next waits for.
  private var describing: Task<Void, Never>?
  /// Who is told each time the device has been described.
  private nonisolated let described = Mutex([UInt64: AsyncStream<Void>.Continuation]())
  private nonisolated let lastListener = Mutex<UInt64>(0)

  /// The IDs of the device's resources, known once the host has given its seed.
  public private(set) var ids: NMOSOcaResourceIDs?
  /// The senders and receivers last described, by resource.
  private(set) var endpoints = [NMOSOcaDescribedEndpoint.Key: NMOSOcaDescribedEndpoint]()
  /// The APIs' views of the bridge, which hold it: the same ones for as long as the node does.
  private weak var provider: NMOSOcaConnectionProvider?
  private weak var model: NMOSOcaDeviceModel?

  /// The device's stream endpoints as IS-05 connections, for the node's Connection API.
  public var connectionProvider: NMOSOcaConnectionProvider {
    if let provider { return provider }
    let provider = NMOSOcaConnectionProvider(bridge: self, logger: logger)
    self.provider = provider
    return provider
  }

  /// The device's objects as an MS-05-02 device model, for the node's IS-12 control protocol.
  public var deviceModel: NMOSOcaDeviceModel {
    if let model { return model }
    let model = NMOSOcaDeviceModel(source: NMOSOcaObjectSource(bridge: self, labels: labels, logger: logger))
    self.model = model
    return model
  }

  /// `host` is asked each time the device is described, not before `run()`, so it can
  /// depend on things the device learns while starting, and can change afterwards.
  /// `controls` are the control APIs the node serves, which the device then lists: by
  /// default the Connection API and the control protocol this bridge provides for.
  /// `labels` keeps the user labels IS-12 sets on objects that have none of their own.
  public nonisolated init(
    store: NMOSResourceStore,
    device: OcaDevice = .shared,
    adaptations: NMOSOcaAdaptations = .standard,
    controls: [NMOSControl] = NMOSConnectionAPI.controls + [NcControlProtocol.control],
    labels: any NMOSOcaLabelStore = NMOSOcaMemoryLabelStore(),
    logger: Logger = Logger(label: "com.padl.NMOSOCABridge"),
    host: @escaping HostProvider
  ) {
    self.store = store
    self.device = device
    self.adaptations = adaptations
    self.controls = controls
    self.labels = labels
    self.logger = logger
    self.host = host
    walker = NMOSOcaEndpointWalker(device: device, adaptations: adaptations)
  }

  /// Describes the device, then again whenever what it was described from changes, until
  /// the task is cancelled. A host whose own part of the description changes, which
  /// nothing the bridge observes announces, calls `describe()` itself.
  public func run() async throws {
    guard await device.deviceManager != nil else {
      logger.error("not describing the OCA device to NMOS: no device manager")
      return
    }
    for await _ in changes() {
      await describe()
    }
    try Task.checkCancellation()
  }

  /// Writes the device's current description to the resource store. The store ignores
  /// what has not changed, so this can be called freely. Each call waits for the one
  /// before, so an older description is never written over a newer one.
  public func describe() async {
    let previous = describing
    let current = Task { @OcaDevice in
      await previous?.value
      await self.describeOnce()
    }
    describing = current
    await current.value
  }

  private func describeOnce() async {
    guard let deviceManager = await device.deviceManager else { return }
    let host = await host()
    let ids = NMOSOcaResourceIDs(seed: host.seed)
    if let previous = self.ids, previous != ids {
      // a different seed is a different node; its old resources must not linger
      await store.reconcile([], replacing: Set(NMOSResourceKind.allCases))
    }
    self.ids = ids
    let (resources, endpoints) = await resources(ids: ids, host: host, deviceManager: deviceManager)
    self.endpoints = endpoints
    await store.reconcile(resources, replacing: Set(NMOSResourceKind.allCases))
    for listener in described.withLock({ Array($0.values) }) { listener.yield() }
  }

  /// Yields each time the device has been described, from now on; the Connection API
  /// reads its connections again at each. Ends when the consumer stops iterating.
  nonisolated func descriptions() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = lastListener.withLock { $0 += 1; return $0 }
    described.withLock { $0[id] = continuation }
    continuation.onTermination = { [weak self] _ in _ = self?.described.withLock { $0.removeValue(forKey: id) } }
    return stream
  }

  /// The sender or receiver with the ID as it was last described, with its endpoint as
  /// the application has it now; nil if it was not described, or the endpoint has gone.
  func endpoint(_ kind: NMOSResourceKind, _ id: NMOSID) -> NMOSOcaDescribedEndpoint? {
    guard let described = endpoints[.init(kind: kind, id: id)],
          let current = NMOSOcaEndpoint(
            application: described.endpoint.application, id: described.endpoint.endpoint.idInternal
          )
    else { return nil }
    return NMOSOcaDescribedEndpoint(endpoint: current, adaptation: described.adaptation)
  }
}
