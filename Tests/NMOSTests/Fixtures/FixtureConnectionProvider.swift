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
import Synchronization

/// A connection provider over endpoints held in memory, for testing the Connection API
/// without a device.
final class FixtureConnectionProvider: NMOSConnectionProvider {
  struct Endpoint {
    var kind: NMOSResourceKind
    var transportType = "urn:x-nmos:transport:rtp"
    var constraints: [[String: NMOSConstraint]] = [[:]]
    var active: NMOSConnectionState
    var transportFile: NMOSTransportFile?
    /// What a transport file staged on a receiver is taken to say, whatever it says.
    var impliedParameters: [NMOSTransportParameters]?
  }

  private struct State {
    var endpoints = [NMOSID: Endpoint]()
    var activations = [(id: NMOSID, staged: NMOSConnectionState)]()
    /// What `activate` throws, to exercise the failure paths.
    var activationError: NMOSConnectionError?
    var forgetsSettingsWhileDisabled = false
    var writesStringsInLowerCase = false
  }

  private let state = Mutex(State())
  private let changes = AsyncStream<(kind: NMOSResourceKind, id: NMOSID)>.makeStream()

  func add(_ endpoint: Endpoint, id: NMOSID) {
    state.withLock { $0.endpoints[id] = endpoint }
  }

  func setTransportFile(_ file: NMOSTransportFile?, sender id: NMOSID) {
    state.withLock { $0.endpoints[id]?.transportFile = file }
  }

  /// Makes the endpoints behave as a device that keeps no settings for a disabled endpoint.
  var forgetsSettingsWhileDisabled: Bool {
    get { state.withLock { $0.forgetsSettingsWhileDisabled } }
    set { state.withLock { $0.forgetsSettingsWhileDisabled = newValue } }
  }

  /// Makes the endpoints read their settings back in their own spelling, as a transport
  /// that keeps an identifier in one canonical form does.
  var writesStringsInLowerCase: Bool {
    get { state.withLock { $0.writesStringsInLowerCase } }
    set { state.withLock { $0.writesStringsInLowerCase = newValue } }
  }

  func failActivations(with error: NMOSConnectionError?) {
    state.withLock { $0.activationError = error }
  }

  var activations: [(id: NMOSID, staged: NMOSConnectionState)] {
    state.withLock { $0.activations }
  }

  /// Changes an endpoint as another control protocol would, behind the API's back.
  func changeExternally(_ id: NMOSID, to active: NMOSConnectionState) {
    let kind = state.withLock { state -> NMOSResourceKind? in
      state.endpoints[id]?.active = active
      return state.endpoints[id]?.kind
    }
    if let kind { changes.continuation.yield((kind, id)) }
  }

  private func endpoint(_ kind: NMOSResourceKind, _ id: NMOSID) throws -> Endpoint {
    guard let endpoint = state.withLock({ $0.endpoints[id] }), endpoint.kind == kind else {
      throw NMOSConnectionError.notFound
    }
    return endpoint
  }

  func connections(_ kind: NMOSResourceKind) async -> [NMOSID] {
    state.withLock { $0.endpoints.filter { $0.value.kind == kind }.keys.sorted() }
  }

  func transportType(_ kind: NMOSResourceKind, id: NMOSID) async throws -> String {
    try endpoint(kind, id).transportType
  }

  func constraints(_ kind: NMOSResourceKind, id: NMOSID) async throws -> [[String: NMOSConstraint]] {
    try endpoint(kind, id).constraints
  }

  func active(_ kind: NMOSResourceKind, id: NMOSID) async throws -> NMOSConnectionState {
    try endpoint(kind, id).active
  }

  func transportFile(sender id: NMOSID) async throws -> NMOSTransportFile? {
    try endpoint(.sender, id).transportFile
  }

  func transportParameters(
    from file: NMOSTransportFile,
    receiver id: NMOSID
  ) async throws -> [NMOSTransportParameters]? {
    try endpoint(.receiver, id).impliedParameters
  }

  func activate(
    _ kind: NMOSResourceKind,
    id: NMOSID,
    staged: NMOSConnectionState
  ) async throws -> NMOSConnectionState {
    _ = try endpoint(kind, id)
    return try state.withLock { state in
      if let error = state.activationError { throw error }
      state.activations.append((id, staged))
      if state.forgetsSettingsWhileDisabled, !staged.masterEnable, let active = state.endpoints[id]?.active {
        return active
      }
      var active = staged
      if state.writesStringsInLowerCase {
        active.transportParameters = active.transportParameters.map { leg in
          leg.mapValues { $0.stringValue.map { .string($0.lowercased()) } ?? $0 }
        }
      }
      state.endpoints[id]?.active = active
      return active
    }
  }

  func connectionChanges() -> AsyncStream<(kind: NMOSResourceKind, id: NMOSID)> {
    changes.stream
  }
}
