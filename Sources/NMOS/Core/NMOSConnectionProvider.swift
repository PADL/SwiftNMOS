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

/// A transport file: SDP for RTP, or whatever document a transport uses to describe a
/// sender to a receiver. Both members are null when there is none.
public struct NMOSTransportFile: Codable, Sendable, Hashable {
  @NMOSNullable public var data: String?
  /// The media type of `data`, such as `application/sdp`.
  @NMOSNullable public var type: String?

  public init(data: String? = nil, type: String? = nil) {
    self.data = data
    self.type = type
  }

  public static let sdpType = "application/sdp"
}

/// The transport parameters of one leg, keyed as the transport's schema names them.
public typealias NMOSTransportParameters = [String: NMOSJSONValue]

/// What a transport parameter may be set to (IS-05 `constraint-schema`); a parameter
/// with no members set is unconstrained.
public struct NMOSConstraint: Codable, Sendable, Hashable {
  public let maximum: NMOSJSONValue?
  public let minimum: NMOSJSONValue?
  public var `enum`: [NMOSJSONValue]?
  public let pattern: String?
  public let description: String?

  public init(
    maximum: NMOSJSONValue? = nil,
    minimum: NMOSJSONValue? = nil,
    enum: [NMOSJSONValue]? = nil,
    pattern: String? = nil,
    description: String? = nil
  ) {
    self.maximum = maximum
    self.minimum = minimum
    self.enum = `enum`
    self.pattern = pattern
    self.description = description
  }

  /// A parameter that cannot be changed from `value`.
  public static func fixed(_ value: NMOSJSONValue) -> Self { Self(enum: [value]) }
}

/// The connection settings of a sender or receiver: the content of IS-05 `/active`, and
/// of `/staged`, apart from the activation.
public struct NMOSConnectionState: Sendable, Hashable {
  public var masterEnable: Bool
  /// The NMOS resource at the other end when it is known to be one: the sender a
  /// receiver is subscribed to, or the receiver a unicast sender sends to.
  public var peerID: NMOSID?
  /// One element per leg; a transport without redundancy has one leg.
  public var transportParameters: [NMOSTransportParameters]
  /// Receivers only: the transport file the settings were taken from.
  public var transportFile: NMOSTransportFile?

  public init(
    masterEnable: Bool,
    peerID: NMOSID? = nil,
    transportParameters: [NMOSTransportParameters],
    transportFile: NMOSTransportFile? = nil
  ) {
    self.masterEnable = masterEnable
    self.peerID = peerID
    self.transportParameters = transportParameters
    self.transportFile = transportFile
  }
}

/// Why a connection provider refused a request; the Connection API maps each to a status.
public enum NMOSConnectionError: Error, Sendable, Equatable {
  /// No such sender or receiver (404).
  case notFound
  /// The settings are not ones the endpoint can take (400).
  case invalid(String)
  /// The endpoint cannot be changed at present (423).
  case locked(String)
  /// The endpoint's transport is not available from this API version (409).
  case unsupportedAPIVersion
  /// The device failed to apply the settings (500).
  case failed(String)
}

/// The connectable endpoints of the device, as IS-05 sees them. The Connection API owns
/// staging, merging, scheduling and the IS-04 updates; the provider owns only what the
/// device is doing and how to change it.
public protocol NMOSConnectionProvider: Sendable {
  /// The senders or receivers that can be connected; `kind` is `.sender` or `.receiver`.
  func connections(_ kind: NMOSResourceKind) async -> [NMOSID]

  /// The transport URN with any subclassification removed, such as `urn:x-nmos:transport:rtp`.
  func transportType(_ kind: NMOSResourceKind, id: NMOSID) async throws -> String

  /// The constraints on every transport parameter, one element per leg. The keys are the
  /// complete set of parameters the endpoint has.
  func constraints(_ kind: NMOSResourceKind, id: NMOSID) async throws -> [[String: NMOSConstraint]]

  /// What the endpoint is doing now, however it came to be doing it.
  func active(_ kind: NMOSResourceKind, id: NMOSID) async throws -> NMOSConnectionState

  /// A sender's transport file, nil when its transport has none or it is not sending.
  func transportFile(sender id: NMOSID) async throws -> NMOSTransportFile?

  /// The transport parameters a transport file implies for a receiver, one element per
  /// leg, which are staged with it; nil if the provider takes no parameters from files.
  func transportParameters(
    from file: NMOSTransportFile,
    receiver id: NMOSID
  ) async throws -> [NMOSTransportParameters]?

  /// Checks settings that are about to be staged, beyond what the constraints express.
  func validate(_ kind: NMOSResourceKind, id: NMOSID, staged: NMOSConnectionState) async throws

  /// Applies the settings, re-applying them even if nothing changed, and returns the
  /// resulting active state with every `auto` resolved.
  func activate(
    _ kind: NMOSResourceKind,
    id: NMOSID,
    staged: NMOSConnectionState
  ) async throws -> NMOSConnectionState

  /// The endpoints whose active state changed other than through `activate`, for
  /// example because another control protocol patched them.
  func connectionChanges() -> AsyncStream<(kind: NMOSResourceKind, id: NMOSID)>
}

public extension NMOSConnectionProvider {
  func validate(_ kind: NMOSResourceKind, id: NMOSID, staged: NMOSConnectionState) async throws {}

  func transportParameters(
    from file: NMOSTransportFile,
    receiver id: NMOSID
  ) async throws -> [NMOSTransportParameters]? { nil }
}
