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

/// The version of an NMOS API, written `v<major>.<minor>` in paths and DNS-SD records.
public struct NMOSAPIVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int

  public init(major: Int, minor: Int) {
    self.major = major
    self.minor = minor
  }

  /// Parses `v1.3`; the fields compare as integers, so v1.12 is later than v1.5.
  public init?(_ string: String) {
    let fields = string.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
    guard string.hasPrefix("v"), fields.count == 2,
          let major = Int(fields[0]), let minor = Int(fields[1]),
          major >= 0, minor >= 0 else { return nil }
    self.init(major: major, minor: minor)
  }

  public var description: String { "v\(major).\(minor)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
  }
}

extension NMOSAPIVersion: Codable {
  public init(from decoder: any Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard let version = Self(string) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "not an NMOS API version: \(string)"
      ))
    }
    self = version
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

public extension NMOSAPIVersion {
  /// IS-04 Node and Registration APIs.
  static let v1_3 = Self(major: 1, minor: 3)
  /// IS-05 Connection API, the last version limited to the transports IS-05 itself defines.
  static let v1_1 = Self(major: 1, minor: 1)
  /// IS-05 Connection API, which admits transports from the register and from manufacturers.
  static let v1_2 = Self(major: 1, minor: 2)
  /// IS-12 control protocol.
  static let v1_0 = Self(major: 1, minor: 0)
}
