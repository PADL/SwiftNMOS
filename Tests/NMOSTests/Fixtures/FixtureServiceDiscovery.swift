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
import Synchronization

/// DNS-SD without a network: records what the node advertises, and lets a test decide
/// what browsing finds.
final class FixtureServiceDiscovery: NMOSServiceDiscovery {
  final class Registration: NMOSServiceRegistration {
    private let state: Mutex<(txt: [String: String], withdrawn: Bool)>
    let advertisement: NMOSServiceAdvertisement

    init(_ advertisement: NMOSServiceAdvertisement) {
      self.advertisement = advertisement
      state = Mutex((advertisement.txt, false))
    }

    var txt: [String: String] { state.withLock { $0.txt } }
    var isWithdrawn: Bool { state.withLock { $0.withdrawn } }

    func update(txt: [String: String]) async throws { state.withLock { $0.txt = txt } }
    func withdraw() async { state.withLock { $0.withdrawn = true } }
  }

  private let state = Mutex((
    registrations: [Registration](),
    browsers: [String: [AsyncStream<[NMOSDiscoveredService]>.Continuation]](),
    published: [String: [NMOSDiscoveredService]]()
  ))

  var registrations: [Registration] { state.withLock { $0.registrations } }

  /// Replaces what browsers of `type` see.
  func publish(_ services: [NMOSDiscoveredService], type: String) {
    let browsers = state.withLock { state in
      state.published[type] = services
      return state.browsers[type] ?? []
    }
    for browser in browsers {
      browser.yield(services)
    }
  }

  func advertise(_ advertisement: NMOSServiceAdvertisement) async throws -> any NMOSServiceRegistration {
    let registration = Registration(advertisement)
    state.withLock { $0.registrations.append(registration) }
    return registration
  }

  func browse(type: String) -> AsyncStream<[NMOSDiscoveredService]> {
    let (stream, continuation) = AsyncStream<[NMOSDiscoveredService]>.makeStream()
    // a browser that starts late is told what is already there, as DNS-SD tells it
    let published = state.withLock { state in
      state.browsers[type, default: []].append(continuation)
      return state.published[type]
    }
    if let published { continuation.yield(published) }
    return stream
  }
}
