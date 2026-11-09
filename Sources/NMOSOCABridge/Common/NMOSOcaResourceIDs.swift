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

/// The IDs of the NMOS resources that stand for an OCA device. They are derived, not
/// stored: the same device gives the same IDs after every restart, which is what lets a
/// controller re-establish its connections. The node and device are named by the seed;
/// an endpoint whose transport names it is named by that, the same on every node.
public struct NMOSOcaResourceIDs: Sendable, Hashable {
  /// The namespace of every ID the bridge derives from its seed. Changing it would change them all.
  public static let namespace = UUID(uuidString: "AB19F44F-B172-4B2D-B1A5-8E1595F308CF")!
  /// The namespace of the IDs derived from a transport's own name for an endpoint, which
  /// any node presenting that endpoint derives alike. Changing it would change them all.
  public static let nativeNamespace = UUID(uuidString: "2A72491D-CC4B-42A3-8690-BD91E5A856D5")!

  public let node: NMOSID
  public let device: NMOSID

  /// `seed` must be unique to the physical device and permanent, such as a MAC address
  /// or a serial number.
  public init(seed: String) {
    node = NMOSID(UUID(version5: "node/\(seed)", namespace: Self.namespace))
    device = NMOSID(UUID(version5: "device", namespace: node.uuid))
  }

  /// The ID of the source, flow, sender or receiver that stands for a stream endpoint of
  /// a media transport application, for an endpoint its transport gives no name.
  public func id(
    _ kind: NMOSResourceKind,
    application: OcaONo,
    endpoint: OcaMediaStreamEndpointID
  ) -> NMOSID {
    NMOSID(UUID(version5: "\(kind.rawValue)/\(application)/\(endpoint)", namespace: device.uuid))
  }

  /// The ID of the source, flow, sender or receiver that stands for the endpoint its
  /// transport names `native`, as `NMOSOcaTransportAdaptation.nativeIdentity(of:)` gives it.
  /// The kind is the name's first component and holds no "/", so kinds never collide.
  public static func id(_ kind: NMOSResourceKind, native: String) -> NMOSID {
    NMOSID(UUID(version5: "\(kind.rawValue)/\(native)", namespace: nativeNamespace))
  }

  /// The ID of the resource that stands for the endpoint a transport names `native`
  /// uniquely only within its own network: derived in this device's namespace.
  public func id(_ kind: NMOSResourceKind, deviceNative native: String) -> NMOSID {
    NMOSID(UUID(version5: "\(kind.rawValue)/\(native)", namespace: device.uuid))
  }

  /// The ID of the resource that stands for the endpoint: from its native name where it
  /// has one, in the namespace its scope calls for, else from the endpoint's place.
  public func id(
    _ kind: NMOSResourceKind,
    of endpoint: NMOSOcaEndpoint,
    native: String?,
    scope: NMOSOcaNativeScope = .universal
  ) -> NMOSID {
    guard let native else {
      return id(kind, application: endpoint.application.objectNumber, endpoint: endpoint.endpoint.idInternal)
    }
    return scope == .universal ? Self.id(kind, native: native) : id(kind, deviceNative: native)
  }
}

/// Where a transport's name for an endpoint is unique. IS-04 IDs share one space in a
/// registry, so a name unique only within one network is qualified by the device.
public enum NMOSOcaNativeScope: Sendable, Hashable {
  /// Unique everywhere, as an IEEE 1722 entity ID (an EUI-64) is.
  case universal
  /// Unique only within the device's own network, as a Dante device name is.
  case device
}
