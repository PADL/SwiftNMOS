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
import SwiftOCA
import SwiftOCADevice

/// RTP streams patched by exchanging SDP: every endpoint of an AES67 application, and
/// the endpoints another application says it describes that way (Dante in AES67 mode).
public struct NMOSOcaRTPAdaptation: NMOSOcaTransportAdaptation {
  public nonisolated init() {}

  public func claims(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    if let application = endpoint.application as? any MediaStreamEndpointSDPRepresentable {
      return await application.usesSessionDescription(endpoint.endpoint.idInternal)
    }
    return endpoint.application is SwiftOCADevice.Aes67OcaMediaTransportApplication
  }
}

/// Native Dante channels, patched by device and channel name.
public struct NMOSOcaDanteAdaptation: NMOSOcaTransportAdaptation {
  public nonisolated init() {}

  public func claims(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    endpoint.application is SwiftOCADevice.DanteOcaMediaTransportApplication
  }

  public func transport(of endpoint: NMOSOcaEndpoint) async -> String { NMOSOcaTransport.dante }
}

/// IEEE 1722 streams, patched by talker entity ID and stream index. The endpoints are
/// those of a Milan entity (AES70-22), the profile of IEEE 1722 the bridge presents.
public struct NMOSOcaIEEE1722Adaptation: NMOSOcaTransportAdaptation {
  public nonisolated init() {}

  /// A clock reference stream is left out: it carries no audio, and NMOS has no kind
  /// of sender or receiver to present it as.
  public func claims(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    endpoint.application.adaptationIdentifier == MilanAdaptation.identifier
      && endpoint.endpoint.currentStreamMode.frameFormat != .crf_milan
  }

  public func transport(of endpoint: NMOSOcaEndpoint) async -> String { NMOSOcaTransport.ieee1722 }
}

/// The adaptations a bridge presents endpoints through, in the order they are asked.
public struct NMOSOcaAdaptations: Sendable {
  public let adaptations: [any NMOSOcaTransportAdaptation]

  public init(_ adaptations: [any NMOSOcaTransportAdaptation]) {
    self.adaptations = adaptations
  }

  /// RTP first, so a Dante endpoint carried by an AES67 flow is patched as RTP.
  public static var standard: NMOSOcaAdaptations {
    NMOSOcaAdaptations([NMOSOcaRTPAdaptation(), NMOSOcaDanteAdaptation(), NMOSOcaIEEE1722Adaptation()])
  }

  /// The first adaptation to claim the endpoint; nil for a transport none of them knows,
  /// which the bridge then leaves out of NMOS.
  @OcaDevice
  public func adaptation(for endpoint: NMOSOcaEndpoint) async -> (any NMOSOcaTransportAdaptation)? {
    for adaptation in adaptations where await adaptation.claims(endpoint) {
      return adaptation
    }
    return nil
  }

  /// What the bridge reads of the device's objects with these adaptations: what it reads
  /// of every endpoint, and what each adaptation reads for the endpoints it claims.
  @OcaDevice
  var observedProperties: NMOSOcaObservedProperties {
    adaptations.reduce(NMOSOcaEndpointWalker.observedProperties + NMOSOcaBridge.observedProperties) {
      $0 + $1.observedProperties
    }
  }
}
