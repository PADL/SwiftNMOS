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

/// A TAI timestamp, written `<seconds>:<nanoseconds>`. IS-04 uses one as each resource's
/// `version` and IS-05 uses them for scheduled activations.
public struct NMOSTimestamp: Sendable, Hashable, Comparable, CustomStringConvertible {
  public var seconds: Int64
  public var nanoseconds: Int32

  /// Seconds TAI is ahead of UTC; constant since the leap second of 2016-12-31.
  public static let taiOffset: Int64 = 37

  public init(seconds: Int64, nanoseconds: Int32 = 0) {
    self.seconds = seconds
    self.nanoseconds = nanoseconds
  }

  public init?(_ string: String) {
    let fields = string.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 2, let seconds = Int64(fields[0]), let nanoseconds = Int32(fields[1]),
          seconds >= 0, (0..<1_000_000_000).contains(nanoseconds) else { return nil }
    self.init(seconds: seconds, nanoseconds: nanoseconds)
  }

  /// The TAI time of a UTC date.
  public init(_ date: Date) {
    let interval = date.timeIntervalSince1970
    let whole = interval.rounded(.down)
    self.init(
      seconds: Int64(whole) + Self.taiOffset,
      nanoseconds: min(Int32((interval - whole) * 1e9), 999_999_999)
    )
  }

  public static func now() -> Self { Self(Date()) }

  public var description: String { "\(seconds):\(nanoseconds)" }

  /// The UTC date this timestamp names.
  public var date: Date {
    Date(timeIntervalSince1970: TimeInterval(seconds - Self.taiOffset) + TimeInterval(nanoseconds) / 1e9)
  }

  /// The next representable instant, so that a later version always compares greater.
  public var next: Self {
    nanoseconds == 999_999_999
      ? Self(seconds: seconds + 1, nanoseconds: 0)
      : Self(seconds: seconds, nanoseconds: nanoseconds + 1)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
  }
}

extension NMOSTimestamp: Codable {
  public init(from decoder: any Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard let timestamp = Self(string) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "not a TAI timestamp: \(string)"
      ))
    }
    self = timestamp
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
