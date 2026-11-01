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

/// Finds Query APIs by DNS-SD, as a controller given no registry does.
public struct NMOSRegistryLocator: Sendable {
  private let discovery: any NMOSServiceDiscovery

  public init(discovery: any NMOSServiceDiscovery) {
    self.discovery = discovery
  }

  /// The Query APIs on offer, best first, each time they change.
  public func queryAPIs() -> AsyncStream<[URL]> {
    let services = discovery.browse(type: NMOSServiceType.query)
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        for await services in services {
          continuation.yield(Self.queryAPIs(services))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Those a client of this version can use, by `pri`, lowest first (IS-04 v1.3 §5). Equal
  /// ones are ordered by name, so that a choice among them stays made.
  static func queryAPIs(_ services: [NMOSDiscoveredService]) -> [URL] {
    services
      .filter {
        $0.txt["api_proto", default: "http"] == "http" &&
          $0.txt["api_ver", default: ""].split(separator: ",")
          .contains(Substring(NMOSQueryClient.apiVersion))
      }
      .sorted {
        let (left, right) = (priority($0), priority($1))
        return left == right ? $0.name < $1.name : left < right
      }
      .compactMap { URL(string: "http://\($0.host):\($0.port)") }
  }

  private static func priority(_ service: NMOSDiscoveredService) -> Int {
    service.txt["pri"].flatMap(Int.init) ?? .max
  }
}
