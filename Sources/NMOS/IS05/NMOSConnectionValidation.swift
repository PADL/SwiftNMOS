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

/// Checks transport parameters a client asks to stage: against the transport's own
/// schema where IS-05 defines one, and against the constraints the endpoint publishes.
enum NMOSConnectionValidation {
  static let rtp = "urn:x-nmos:transport:rtp"

  /// The transports IS-05 v1.1 itself defines; any other needs v1.2.
  static let transportsBeforeV1_2: Set<String> = [
    rtp, "urn:x-nmos:transport:dash", "urn:x-nmos:transport:mqtt", "urn:x-nmos:transport:websocket",
  ]

  /// Throws a bad request if `value` is not one the parameter may be staged with.
  static func check(
    _ name: String,
    _ value: NMOSJSONValue,
    constraint: NMOSConstraint,
    transport: String,
    kind: NMOSResourceKind
  ) throws {
    if transport == rtp {
      try checkRTP(name, value, kind: kind)
      // `auto` asks the endpoint to choose, so the constraints on a choice do not apply
      if value == "auto" { return }
    }
    if let allowed = constraint.enum, !allowed.contains(where: { equal($0, value) }) {
      throw NMOSHTTPError.badRequest("`\(name)` is not one of the values the constraints allow")
    }
    // null is a parameter that is not set, which a range or a pattern says nothing about;
    // an endpoint reports null for what it has not been given, and may be sent it back
    if value.isNull { return }
    if let minimum = constraint.minimum?.doubleValue {
      guard let number = value.doubleValue, number >= minimum else {
        throw NMOSHTTPError.badRequest("`\(name)` is below the minimum the constraints allow")
      }
    }
    if let maximum = constraint.maximum?.doubleValue {
      guard let number = value.doubleValue, number <= maximum else {
        throw NMOSHTTPError.badRequest("`\(name)` is above the maximum the constraints allow")
      }
    }
    if let pattern = constraint.pattern {
      guard let string = value.stringValue, string.range(of: pattern, options: .regularExpression) != nil else {
        throw NMOSHTTPError.badRequest("`\(name)` does not match the pattern the constraints require")
      }
    }
  }

  /// JSON equality in which 5 and 5.0 are the same number.
  static func equal(_ lhs: NMOSJSONValue, _ rhs: NMOSJSONValue) -> Bool {
    if let left = lhs.doubleValue, let right = rhs.doubleValue { return left == right }
    return lhs == rhs
  }

  // MARK: - RTP (IS-05 sender_transport_params_rtp, receiver_transport_params_rtp)

  private enum RTPType {
    case address(auto: Bool, null: Bool)
    case port(minimum: Int64)
    case boolean
    case choice([String])
    case integer(ClosedRange<Int64>)
  }

  private static func rtpType(_ name: String, kind: NMOSResourceKind) -> RTPType? {
    let sender = kind == .sender
    switch name {
    case "source_ip": return .address(auto: sender, null: !sender)
    case "destination_ip" where sender: return .address(auto: true, null: false)
    case "multicast_ip" where !sender: return .address(auto: false, null: true)
    case "interface_ip" where !sender: return .address(auto: true, null: false)
    case "fec_destination_ip", "rtcp_destination_ip": return .address(auto: true, null: false)
    case "destination_port", "fec1D_destination_port", "fec2D_destination_port", "rtcp_destination_port":
      return .port(minimum: 1)
    case "source_port" where sender, "fec1D_source_port" where sender, "fec2D_source_port" where sender,
         "rtcp_source_port" where sender:
      return .port(minimum: 0)
    case "rtp_enabled", "fec_enabled", "rtcp_enabled": return .boolean
    case "fec_mode": return .choice(sender ? ["1D", "2D"] : ["auto", "1D", "2D"])
    case "fec_type" where sender: return .choice(["XOR", "Reed-Solomon"])
    case "fec_block_width" where sender, "fec_block_height" where sender: return .integer(4...200)
    default: return nil
    }
  }

  private static func checkRTP(_ name: String, _ value: NMOSJSONValue, kind: NMOSResourceKind) throws {
    // externally defined parameters are any scalar, which the request parser has checked
    if name.hasPrefix("ext_") { return }
    guard let type = rtpType(name, kind: kind) else {
      throw NMOSHTTPError.badRequest("Un-recognised parameter '\(name)'")
    }
    let valid = switch type {
    case let .address(auto, null):
      (value.isNull && null) || (value == "auto" && auto) || value.stringValue.map(isAddress) == true
    case let .port(minimum):
      value == "auto" || (value.stringValue == nil && value.integerValue.map { (minimum...65535).contains($0) } == true)
    case .boolean:
      value.boolValue != nil
    case let .choice(choices):
      value.stringValue.map(choices.contains) == true
    case let .integer(range):
      value.stringValue == nil && value.integerValue.map(range.contains) == true
    }
    guard valid else {
      throw NMOSHTTPError.badRequest("`\(name)` is not a valid value for an RTP \(kind.rawValue)")
    }
  }

  static func isAddress(_ string: String) -> Bool {
    var ip4 = in_addr()
    var ip6 = in6_addr()
    return inet_pton(AF_INET, string, &ip4) == 1 || inet_pton(AF_INET6, string, &ip6) == 1
  }
}
