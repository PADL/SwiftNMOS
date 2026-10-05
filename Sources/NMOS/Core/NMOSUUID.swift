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

import Crypto
import Foundation

public extension UUID {
  /// A name-based (version 5, SHA-1) UUID per RFC 4122 §4.3: the same namespace and name
  /// always give the same UUID, which is how resource IDs survive a restart.
  init(version5 name: String, namespace: UUID) {
    var hasher = Insecure.SHA1()
    withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
    hasher.update(data: Data(name.utf8))
    var bytes = Array(hasher.finalize().prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    self.init(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  /// The lower-case form the NMOS schemas require; Foundation's is upper-case. Written
  /// out here, as every ID in every resource is, and Foundation formats one slowly.
  var nmosString: String {
    withUnsafeBytes(of: uuid) { bytes in
      String(unsafeUninitializedCapacity: 36) { text in
        var count = 0
        for (index, byte) in bytes.enumerated() {
          if [4, 6, 8, 10].contains(index) {
            text[count] = UInt8(ascii: "-")
            count += 1
          }
          text[count] = Self.hexDigits[Int(byte >> 4)]
          text[count + 1] = Self.hexDigits[Int(byte & 0x0F)]
          count += 2
        }
        return count
      }
    }
  }

  private static let hexDigits = Array("0123456789abcdef".utf8)
}

/// A resource ID as NMOS writes it. Wrapping `UUID` keeps the lower-case spelling in one
/// place, because `UUID` itself encodes in upper case.
public struct NMOSID: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let uuid: UUID

  public init(_ uuid: UUID) { self.uuid = uuid }

  public init?(_ string: String) {
    guard let uuid = UUID(uuidString: string) else { return nil }
    self.uuid = uuid
  }

  public var description: String { uuid.nmosString }

  /// The order of the IDs as written, which is the order of their octets.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    withUnsafeBytes(of: lhs.uuid.uuid) { lhs in
      withUnsafeBytes(of: rhs.uuid.uuid) { rhs in lhs.lexicographicallyPrecedes(rhs) }
    }
  }
}

extension NMOSID: Codable {
  public init(from decoder: any Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard let id = Self(string) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "not a UUID: \(string)"
      ))
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
