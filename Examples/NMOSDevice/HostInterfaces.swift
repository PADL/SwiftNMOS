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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A network interface of the host that is up, not loopback, and has an IPv4 address.
struct HostInterface: Sendable {
  let name: String
  let address: String
  let prefixLength: Int
  /// Six lower-case hyphen-separated octets, as IS-04 writes a `port_id`.
  let macAddress: String

  /// The host's interfaces, in the order the system lists them.
  static func all() -> [HostInterface] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }

    var addresses = [(name: String, address: String, prefixLength: Int)]()
    var macAddresses = [String: String]()
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(entry.pointee.ifa_flags)
      guard let address = entry.pointee.ifa_addr, flags & Int32(IFF_UP) != 0,
            flags & Int32(IFF_LOOPBACK) == 0 else { continue }
      let name = String(cString: entry.pointee.ifa_name)
      switch Int32(address.pointee.sa_family) {
      case AF_INET:
        guard let text = ipv4(address), let mask = entry.pointee.ifa_netmask.flatMap(ipv4Bits) else { continue }
        addresses.append((name, text, mask))
      case linkFamily:
        if let mac = macAddress(address) { macAddresses[name] = mac }
      default:
        continue
      }
    }
    return addresses.compactMap { entry in
      macAddresses[entry.name].map {
        HostInterface(name: entry.name, address: entry.address, prefixLength: entry.prefixLength, macAddress: $0)
      }
    }
  }

  #if canImport(Darwin)
  private static let linkFamily = AF_LINK
  #else
  private static let linkFamily = AF_PACKET
  #endif

  private static func ipv4(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
      var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      var bytes = address.pointee.sin_addr
      guard inet_ntop(AF_INET, &bytes, &text, socklen_t(text.count)) != nil else { return nil }
      return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  private static func ipv4Bits(_ mask: UnsafeMutablePointer<sockaddr>) -> Int? {
    mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { mask in
      UInt32(bigEndian: mask.pointee.sin_addr.s_addr).nonzeroBitCount
    }
  }

  /// The hardware address of a link-layer entry, if it has a six-octet one.
  private static func macAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
    #if canImport(Darwin)
    return address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
      guard link.pointee.sdl_alen == 6,
            let data = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }
      // the name comes first, and both may run past the declared size of sdl_data
      let start = UnsafeRawPointer(link).advanced(by: data + Int(link.pointee.sdl_nlen))
      return octets(Array(UnsafeRawBufferPointer(start: start, count: 6)))
    }
    #else
    // a sockaddr_ll, which Glibc does not import: sll_halen at byte 11, sll_addr from 12
    let link = UnsafeRawPointer(address)
    guard link.load(fromByteOffset: 11, as: UInt8.self) == 6 else { return nil }
    return octets(Array(UnsafeRawBufferPointer(start: link.advanced(by: 12), count: 6)))
    #endif
  }

  private static func octets(_ bytes: [UInt8]) -> String? {
    guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
    return bytes.map { String(format: "%02x", $0) }.joined(separator: "-")
  }
}
