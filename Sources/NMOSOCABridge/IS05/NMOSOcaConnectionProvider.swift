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
import SwiftOCA
import SwiftOCADevice

/// The stream endpoints of an OCA device as IS-05 connections. Each endpoint is read and
/// changed through the adaptation that claims it, so the provider itself knows nothing
/// of any one transport.
@OcaDevice
public final class NMOSOcaConnectionProvider: NMOSConnectionProvider {
  public typealias IDProvider = @Sendable () async -> NMOSOcaResourceIDs?

  private struct Key: Hashable {
    let kind: NMOSResourceKind
    let id: NMOSID
  }

  /// Which adaptation has an endpoint. Deciding it means asking each adaptation in turn,
  /// and an adaptation may have to ask the device, so it is decided once and kept.
  private struct Claim {
    let application: SwiftOCADevice.OcaMediaTransportApplication
    let endpointID: OcaMediaStreamEndpointID
    let adaptation: any NMOSOcaConnecting
  }

  private struct Claims {
    let ids: NMOSOcaResourceIDs
    let made: ContinuousClock.Instant
    let claims: [Key: Claim]
  }

  /// A bound on how long claims are kept, for whatever changes one without a property
  /// of the applications or their interfaces changing.
  private static let maximumClaimAge = Duration.seconds(30)

  private var claims: Claims?
  /// Counts invalidations, so that claims decided across one are not kept.
  private var generation: UInt64 = 0
  private var invalidator: Task<Void, Never>?

  private let walker: NMOSOcaEndpointWalker
  private let adaptations: NMOSOcaAdaptations
  private let device: OcaDevice
  private let logger: Logger
  private let ids: IDProvider

  /// `ids` gives the IDs the device's resources are known by, which is what the bridge
  /// describing the device to IS-04 derived; until it has, there are no connections.
  public nonisolated init(
    adaptations: NMOSOcaAdaptations = .standard,
    device: OcaDevice = .shared,
    logger: Logger = Logger(label: "com.padl.NMOSOCABridge.Connection"),
    ids: @escaping IDProvider
  ) {
    self.adaptations = adaptations
    self.device = device
    self.logger = logger
    self.ids = ids
    walker = NMOSOcaEndpointWalker(device: device, adaptations: adaptations)
  }

  deinit {
    invalidator?.cancel()
  }

  /// The endpoints and their statuses, and the session agents observed below.
  static let observedProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaMediaTransportApplication.self, [
    .init(defLevel: 3, propertyIndex: 10), // endpoints
    .init(defLevel: 3, propertyIndex: 11), // endpointStatuses
    .init(defLevel: 3, propertyIndex: 13), // transportSessionControlAgentONos
  ])

  // MARK: - Finding endpoints

  /// The claims on the device's endpoints, decided again only when something they were
  /// decided from has changed. Every call of the Connection API comes through here, and
  /// one request makes several.
  private func claimed() async -> [Key: Claim] {
    startInvalidator()
    guard let ids = await ids() else { return [:] }
    if let claims, claims.ids == ids, claims.made.duration(to: .now) < Self.maximumClaimAge {
      return claims.claims
    }
    let started = generation
    var decided = [Key: Claim]()
    for endpoint in await walker.endpoints {
      guard let adaptation = await adaptations.adaptation(for: endpoint) as? any NMOSOcaConnecting
      else { continue }
      decided[Key(kind: endpoint.kind, id: endpoint.id(endpoint.kind, in: ids))] = Claim(
        application: endpoint.application, endpointID: endpoint.endpoint.idInternal, adaptation: adaptation
      )
    }
    // something changed while the adaptations were being asked, so this is not kept
    if generation == started { claims = Claims(ids: ids, made: .now, claims: decided) }
    return decided
  }

  private func invalidate() {
    claims = nil
    generation &+= 1
  }

  /// Observes the applications from the first use on, forgetting the claims at each change.
  private func startInvalidator() {
    guard invalidator == nil else { return }
    let changes = walker.changes()
    invalidator = Task { @OcaDevice [weak self] in
      for await _ in changes {
        guard let self else { return }
        self.invalidate()
      }
    }
  }

  /// The endpoint a claim is on, as its application has it now.
  private func endpoint(of claim: Claim) -> NMOSOcaEndpoint? {
    guard let endpoint = try? claim.application.endpoint(claim.endpointID) else { return nil }
    return NMOSOcaEndpoint(
      application: claim.application,
      endpoint: endpoint,
      status: claim.application.endpointStatuses[claim.endpointID]
    )
  }

  private func find(
    _ kind: NMOSResourceKind,
    _ id: NMOSID
  ) async throws -> (endpoint: NMOSOcaEndpoint, adaptation: any NMOSOcaConnecting) {
    let key = Key(kind: kind, id: id)
    if let claim = await claimed()[key], let endpoint = endpoint(of: claim) {
      return (endpoint, claim.adaptation)
    }
    // not known, or gone: the endpoints may have changed since the claims were decided
    invalidate()
    guard let claim = await claimed()[key], let endpoint = endpoint(of: claim) else {
      throw NMOSConnectionError.notFound
    }
    return (endpoint, claim.adaptation)
  }

  // MARK: - NMOSConnectionProvider

  public func connections(_ kind: NMOSResourceKind) async -> [NMOSID] {
    await claimed().keys.filter { $0.kind == kind }.map(\.id).sorted()
  }

  public func transportType(_ kind: NMOSResourceKind, id: NMOSID) async throws -> String {
    let (endpoint, adaptation) = try await find(kind, id)
    return await adaptation.transportType(of: endpoint)
  }

  public func constraints(_ kind: NMOSResourceKind, id: NMOSID) async throws -> [[String: NMOSConstraint]] {
    let (endpoint, adaptation) = try await find(kind, id)
    return try await adaptation.constraints(of: endpoint)
  }

  public func active(_ kind: NMOSResourceKind, id: NMOSID) async throws -> NMOSConnectionState {
    let (endpoint, adaptation) = try await find(kind, id)
    return try await adaptation.active(of: endpoint)
  }

  public func transportFile(sender id: NMOSID) async throws -> NMOSTransportFile? {
    let (endpoint, adaptation) = try await find(.sender, id)
    return try await adaptation.transportFile(of: endpoint)
  }

  public func transportParameters(
    from file: NMOSTransportFile,
    receiver id: NMOSID
  ) async throws -> [NMOSTransportParameters]? {
    let (endpoint, adaptation) = try await find(.receiver, id)
    return try await adaptation.transportParameters(from: file, for: endpoint)
  }

  public func activate(
    _ kind: NMOSResourceKind,
    id: NMOSID,
    staged: NMOSConnectionState
  ) async throws -> NMOSConnectionState {
    let (endpoint, adaptation) = try await find(kind, id)
    do {
      try await adaptation.activate(endpoint, staged: staged)
    } catch {
      logger.info("activation of \(kind.rawValue) \(id) failed: \(error)")
      throw NMOSConnectionError(error)
    }
    // the endpoint that was found is a copy from before the change
    return try await adaptation.active(of: endpoint.refreshed)
  }

  // MARK: - Changes

  public nonisolated func connectionChanges() -> AsyncStream<(kind: NMOSResourceKind, id: NMOSID)> {
    AsyncStream { continuation in
      let task = Task { @OcaDevice in await self.observe(continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Reports every endpoint, and every one that has gone, each time something the
  /// connections are read from changes. The caller compares each with what it last
  /// recorded, activations included, which a comparison here could not know of.
  private func observe(_ continuation: AsyncStream<(kind: NMOSResourceKind, id: NMOSID)>.Continuation) async {
    var reported = Set<Key>()
    for await _ in changes() {
      let current = Set(await claimed().filter { endpoint(of: $0.value) != nil }.keys)
      for key in reported.union(current) {
        continuation.yield((key.kind, key.id))
      }
      reported = current
    }
    continuation.finish()
  }

  /// The objects connections are read from that the walker does not observe: the device
  /// manager, whose name an adaptation may give its senders, and the session agents.
  private var connectionObjects: [SwiftOCADevice.OcaRoot] {
    get async {
      var objects: [SwiftOCADevice.OcaRoot] = await device.deviceManager.map { [$0] } ?? []
      for application in await walker.applications {
        for oNo in application.transportSessionControlAgentONos {
          if let agent: SwiftOCADevice.OcaRoot = await device.resolve(objectNumber: oNo) { objects.append(agent) }
        }
      }
      return objects
    }
  }

  private nonisolated func changes() -> AsyncStream<Void> {
    walker.changes { await self.connectionObjects }
  }
}
