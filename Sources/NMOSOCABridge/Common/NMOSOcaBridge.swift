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

/// Describes an OCA device as NMOS resources and keeps the description current. The
/// device is read through its standard AES70 objects only, so the same bridge serves
/// any SwiftOCADevice device.
@OcaDevice
public final class NMOSOcaBridge: Sendable {
  public typealias HostProvider = @Sendable () async -> NMOSOcaHost

  let device: OcaDevice
  private let store: NMOSResourceStore
  private let logger: Logger
  let walker: NMOSOcaEndpointWalker
  let adaptations: NMOSOcaAdaptations
  let controls: [NMOSControl]
  private let host: HostProvider
  /// The describe in progress, which the next waits for.
  private var describing: Task<Void, Never>?

  /// The IDs of the device's resources, known once the host has given its seed.
  public private(set) var ids: NMOSOcaResourceIDs?

  /// `host` is asked each time the device is described, not before `run()`, so it can
  /// depend on things the device learns while starting, and can change afterwards.
  /// `controls` are the control APIs the node serves, which the device then lists.
  public nonisolated init(
    store: NMOSResourceStore,
    device: OcaDevice = .shared,
    adaptations: NMOSOcaAdaptations = .standard,
    controls: [NMOSControl] = [],
    logger: Logger = Logger(label: "com.padl.NMOSOCABridge"),
    host: @escaping HostProvider
  ) {
    self.store = store
    self.device = device
    self.adaptations = adaptations
    self.controls = controls
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
    await store.reconcile(
      resources(ids: ids, host: host, deviceManager: deviceManager),
      replacing: Set(NMOSResourceKind.allCases)
    )
  }
}
