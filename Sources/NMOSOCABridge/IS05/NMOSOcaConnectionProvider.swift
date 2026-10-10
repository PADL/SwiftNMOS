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

/// The stream endpoints of an OCA device as IS-05 connections, as the bridge last
/// described them. Each endpoint is read and changed through the adaptation that claims
/// it, so the provider itself knows nothing of any one transport.
@OcaDevice
public final class NMOSOcaConnectionProvider: NMOSConnectionProvider {
  private let bridge: NMOSOcaBridge
  private let logger: Logger

  init(bridge: NMOSOcaBridge, logger: Logger) {
    self.bridge = bridge
    self.logger = logger
  }

  /// The endpoint as it is now, else as it is once the device is described again: the
  /// endpoints may have changed since the bridge last described them.
  private func find(_ kind: NMOSResourceKind, _ id: NMOSID) async throws -> NMOSOcaDescribedEndpoint {
    if let found = bridge.endpoint(kind, id) { return found }
    await bridge.describe()
    guard let found = bridge.endpoint(kind, id) else { throw NMOSConnectionError.notFound }
    return found
  }

  // MARK: - NMOSConnectionProvider

  public func connections(_ kind: NMOSResourceKind) async -> [NMOSID] {
    bridge.endpoints.keys.filter { $0.kind == kind }.map(\.id).sorted()
  }

  public func transportType(_ kind: NMOSResourceKind, id: NMOSID) async throws -> String {
    let found = try await find(kind, id)
    return await found.adaptation.transportType(of: found.endpoint)
  }

  public func constraints(_ kind: NMOSResourceKind, id: NMOSID) async throws -> [[String: NMOSConstraint]] {
    let found = try await find(kind, id)
    return try await found.adaptation.constraints(of: found.endpoint)
  }

  public func active(_ kind: NMOSResourceKind, id: NMOSID) async throws -> NMOSConnectionState {
    let found = try await find(kind, id)
    return try await found.adaptation.active(of: found.endpoint)
  }

  public func transportFile(sender id: NMOSID) async throws -> NMOSTransportFile? {
    let found = try await find(.sender, id)
    return try await found.adaptation.transportFile(of: found.endpoint)
  }

  public func transportParameters(
    from file: NMOSTransportFile,
    receiver id: NMOSID
  ) async throws -> [NMOSTransportParameters]? {
    let found = try await find(.receiver, id)
    return try await found.adaptation.transportParameters(from: file, for: found.endpoint)
  }

  public func activate(
    _ kind: NMOSResourceKind,
    id: NMOSID,
    staged: NMOSConnectionState
  ) async throws -> NMOSConnectionState {
    let found = try await find(kind, id)
    do {
      try await found.adaptation.activate(found.endpoint, staged: staged)
    } catch {
      logger.info("activation of \(kind.rawValue) \(id) failed: \(error)")
      throw NMOSConnectionError(error)
    }
    // the endpoint that was found is a copy from before the change
    return try await found.adaptation.active(of: found.endpoint.refreshed)
  }

  /// The connections are read from the description, so they change when it does.
  public nonisolated func connectionChanges() -> AsyncStream<Void> {
    bridge.descriptions()
  }
}
