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

/// What the browses of the default domains and of each search domain have found, put
/// together as IS-04 says: what unicast DNS finds is used, and what mDNS finds only
/// while unicast DNS finds nothing.
actor NMOSOcaDiscoveredServices {
  private let continuation: AsyncStream<[NMOSDiscoveredService]>.Continuation
  /// Found by the browse of the default domains, which is mDNS's `local` at least.
  private var byDefault = [NMOSDiscoveredService]()
  private var bySearchDomain = [String: [NMOSDiscoveredService]]()
  private var reported: [NMOSDiscoveredService]?

  init(continuation: AsyncStream<[NMOSDiscoveredService]>.Continuation) {
    self.continuation = continuation
  }

  /// A nil domain is the browse of the default domains.
  func found(_ services: [NMOSDiscoveredService], in domain: String?) {
    if let domain {
      bySearchDomain[domain] = services.isEmpty ? nil : services
    } else {
      byDefault = services
    }
    report()
  }

  private func report() {
    var seen = Set<NMOSDiscoveredService>()
    let unicast = bySearchDomain.keys.sorted().flatMap { bySearchDomain[$0] ?? [] }
      .filter { seen.insert($0).inserted }
    let services = unicast.isEmpty ? byDefault : unicast
    // nothing is said until something is found: a browse cannot say there is nothing
    guard services != reported, reported != nil || !services.isEmpty else { return }
    reported = services
    continuation.yield(services)
  }
}
