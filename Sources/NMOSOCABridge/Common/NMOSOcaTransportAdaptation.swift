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
import SwiftOCADevice

/// What the bridge needs to know about one media transport (AES67, Dante, Milan) that
/// AES70 leaves to the adaptation: which endpoints are its, how IS-04 describes them,
/// and how IS-05 reads and changes their connections.
@OcaDevice
public protocol NMOSOcaTransportAdaptation: Sendable {
  /// Whether this adaptation presents the endpoint. Adaptations are asked in the order
  /// they were registered and the first to claim an endpoint has it, so one transport
  /// can take some endpoints of an application (Dante channels carried by AES67 flows).
  func claims(_ endpoint: NMOSOcaEndpoint) async -> Bool

  /// What these methods read of the device's objects beyond the endpoint's own helpers,
  /// which the bridge then observes.
  var observedProperties: NMOSOcaObservedProperties { get }

  // MARK: IS-04

  /// The transport URN, with its subclassification where it has one, such as
  /// `urn:x-nmos:transport:rtp.mcast`.
  func transport(of endpoint: NMOSOcaEndpoint) async -> String

  /// The names of the node interfaces the endpoint is bound to, one per leg.
  func interfaceBindings(of endpoint: NMOSOcaEndpoint) async -> [String]

  /// Whether a sending endpoint has a transport file to publish at `manifest_href`.
  func hasTransportFile(_ endpoint: NMOSOcaEndpoint) async -> Bool

  // MARK: IS-05

  /// The constraints on a receiving endpoint's transport parameters, one element per leg.
  /// A sender's stream is set up outside NMOS, so its parameters are fixed at what they are.
  func receiverConstraints(of endpoint: NMOSOcaEndpoint) async throws -> [[String: NMOSConstraint]]

  /// The endpoint's current connection, read from its adaptation data. The peer ID is
  /// nil: the device does not know which NMOS resource is at the other end.
  func active(of endpoint: NMOSOcaEndpoint) async throws -> NMOSConnectionState

  /// A sending endpoint's transport file, nil when it has none at present.
  func transportFile(of endpoint: NMOSOcaEndpoint) async throws -> NMOSTransportFile?

  /// The transport parameters a transport file implies for a receiving endpoint, one
  /// element per leg; a transport that takes none from files refuses the file.
  func transportParameters(
    from file: NMOSTransportFile,
    for endpoint: NMOSOcaEndpoint
  ) async throws -> [NMOSTransportParameters]?

  /// Applies the settings to a receiving endpoint through the application's AES70
  /// methods. Throws `NMOSConnectionError`; the new state is read back from the device
  /// afterwards. A sender takes only the enablement it already has.
  func activateReceiver(_ endpoint: NMOSOcaEndpoint, staged: NMOSConnectionState) async throws
}

public extension NMOSOcaTransportAdaptation {
  /// The transport URN with any subclassification removed, as IS-05 `/transporttype`
  /// reports it.
  func transportType(of endpoint: NMOSOcaEndpoint) async -> String {
    await NMOSOcaTransport.base(of: transport(of: endpoint))
  }

  /// The interfaces AES70 says the endpoint is assigned to.
  func interfaceBindings(of endpoint: NMOSOcaEndpoint) async -> [String] {
    await endpoint.interfaceNames
  }

  /// IS-04 requires an RTP sender to give the location of its SDP file; the other
  /// transports have no transport file, so their `manifest_href` is null.
  func hasTransportFile(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    guard endpoint.isSender else { return false }
    return await transportType(of: endpoint) == NMOSOcaTransport.rtp
  }

  /// An endpoint is active while its connection is enabled, which is IS-05's
  /// `master_enable`: IS-04 and IS-05 must say the same of it.
  func isActive(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    await (try? active(of: endpoint).masterEnable) ?? false
  }

  func transportFile(of endpoint: NMOSOcaEndpoint) async throws -> NMOSTransportFile? { nil }

  func transportParameters(
    from file: NMOSTransportFile,
    for endpoint: NMOSOcaEndpoint
  ) async throws -> [NMOSTransportParameters]? {
    throw await NMOSConnectionError.noTransportFile(transportType(of: endpoint))
  }

  func constraints(of endpoint: NMOSOcaEndpoint) async throws -> [[String: NMOSConstraint]] {
    guard endpoint.isSender else { return try await receiverConstraints(of: endpoint) }
    return try await active(of: endpoint).transportParameters.map { $0.mapValues { .fixed($0) } }
  }

  func activate(_ endpoint: NMOSOcaEndpoint, staged: NMOSConnectionState) async throws {
    guard endpoint.isSender else { return try await activateReceiver(endpoint, staged: staged) }
    // the constraints admit only what the sender is already doing
    guard try await staged.masterEnable == active(of: endpoint).masterEnable else {
      throw NMOSConnectionError.invalid("This sender is enabled and disabled where its stream is set up")
    }
  }
}
