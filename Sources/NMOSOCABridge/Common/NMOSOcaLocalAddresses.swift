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

/// The IPv4 addresses of the host's interfaces that are up, other than loopback: where
/// the host can be reached, and what an application bound to no interface of its own
/// sends and receives on.
public func localIPv4Addresses() -> [String] {
  var list: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&list) == 0 else { return [] }
  defer { freeifaddrs(list) }

  var addresses = [String]()
  var cursor = list
  while let interface = cursor?.pointee {
    cursor = interface.ifa_next
    guard let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
          interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
    else { continue }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
      addresses.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
  }
  return addresses
}
