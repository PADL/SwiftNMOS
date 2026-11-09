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

/// The NMOS transport URNs the bridge gives OCA media transport applications. Dante and
/// IEEE 1722 are not in AMWA's register of transports, whose `urn:x-nmos:` namespace is
/// AMWA's own, so they are named in PADL's; IS-04 v1.3 and IS-05 v1.2 admit any
/// manufacturer's namespace. Their transport parameters are described by the JSON
/// schemas in `schemas/`.
public enum NMOSOcaTransport {
  /// RTP, for AES67 and for Dante endpoints carried by AES67 flows.
  public static let rtp = "urn:x-nmos:transport:rtp"
  public static let rtpMulticast = "urn:x-nmos:transport:rtp.mcast"
  public static let rtpUnicast = "urn:x-nmos:transport:rtp.ucast"
  /// Native Dante audio transport, patched by device and channel name.
  public static let dante = "urn:x-padl:transport:dante"
  /// IEEE 1722 (AVTP) streams, patched by talker entity ID and stream index; a Milan
  /// entity is the profile of it the bridge presents.
  public static let ieee1722 = "urn:x-padl:transport:ieee1722"

  /// The name of a transport for messages: "Dante", "IEEE 1722" or the URN itself.
  public static func displayName(of transport: String) -> String {
    switch base(of: transport) {
    case dante: "Dante"
    case ieee1722: "IEEE 1722"
    case rtp: "RTP"
    default: transport
    }
  }

  /// The URN with any subclassification removed, as IS-05 `/transporttype` reports it.
  public static func base(of transport: String) -> String {
    guard let lastColon = transport.lastIndex(of: ":"),
          let dot = transport[lastColon...].firstIndex(of: ".") else { return transport }
    return String(transport[..<dot])
  }
}
