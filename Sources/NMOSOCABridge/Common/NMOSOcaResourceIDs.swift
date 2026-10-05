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
/// controller re-establish its connections.
public struct NMOSOcaResourceIDs: Sendable, Hashable {
  /// The namespace of every ID the bridge derives. Changing it would change them all.
  public static let namespace = UUID(uuidString: "AB19F44F-B172-4B2D-B1A5-8E1595F308CF")!

  public let node: NMOSID
  public let device: NMOSID

  /// `seed` must be unique to the physical device and permanent, such as a MAC address
  /// or a serial number.
  public init(seed: String) {
    node = NMOSID(UUID(version5: "node/\(seed)", namespace: Self.namespace))
    device = NMOSID(UUID(version5: "device", namespace: node.uuid))
  }

  /// The ID of the source, flow, sender or receiver that stands for a stream endpoint of
  /// a media transport application.
  public func id(
    _ kind: NMOSResourceKind,
    application: OcaONo,
    endpoint: OcaMediaStreamEndpointID
  ) -> NMOSID {
    NMOSID(UUID(version5: "\(kind.rawValue)/\(application)/\(endpoint)", namespace: device.uuid))
  }
}
