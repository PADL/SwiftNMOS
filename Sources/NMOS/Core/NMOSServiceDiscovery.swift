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

/// The DNS-SD service types of IS-04.
public enum NMOSServiceType {
  /// A Node API, advertised for peer-to-peer operation.
  public static let node = "_nmos-node._tcp"
  /// A Registration API (IS-04 v1.3).
  public static let registration = "_nmos-register._tcp"
  public static let query = "_nmos-query._tcp"
}

/// A service to advertise by DNS-SD.
public struct NMOSServiceAdvertisement: Sendable, Hashable {
  public var type: String
  /// The instance name; nil lets the responder use the host's name.
  public var name: String?
  public var port: UInt16
  public var txt: [String: String]

  public init(type: String, name: String? = nil, port: UInt16, txt: [String: String]) {
    self.type = type
    self.name = name
    self.port = port
    self.txt = txt
  }
}

/// A live advertisement.
public protocol NMOSServiceRegistration: Sendable {
  /// Replaces the TXT record, which is how the `ver_` counters are published.
  func update(txt: [String: String]) async throws
  func withdraw() async
}

/// A service found by browsing, resolved to where it can be reached.
public struct NMOSDiscoveredService: Sendable, Hashable {
  public var name: String
  public var host: String
  public var port: UInt16
  public var txt: [String: String]

  public init(name: String, host: String, port: UInt16, txt: [String: String]) {
    self.name = name
    self.host = host
    self.port = port
    self.txt = txt
  }
}

/// DNS-SD as IS-04 uses it: advertising the Node API and finding a Registration API.
public protocol NMOSServiceDiscovery: Sendable {
  func advertise(_ advertisement: NMOSServiceAdvertisement) async throws -> any NMOSServiceRegistration

  /// The resolved services of a type, delivered again in full whenever the set changes.
  func browse(type: String) -> AsyncStream<[NMOSDiscoveredService]>
}
