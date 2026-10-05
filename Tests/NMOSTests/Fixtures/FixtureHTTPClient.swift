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

import FlyingFox
import Foundation
import NMOS
import Synchronization

/// An HTTP client that records each request and answers it from a closure, standing in
/// for a Registration API.
final class FixtureHTTPClient: NMOSHTTPClient {
  struct Request: Equatable {
    var method: HTTPMethod
    var url: URL
    var body: Data?
  }

  typealias Responder = @Sendable (Request) throws -> NMOSHTTPClientResponse

  private let state: Mutex<(requests: [Request], responder: Responder)>

  init(responder: @escaping Responder = { _ in NMOSHTTPClientResponse(status: 200) }) {
    state = Mutex(([], responder))
  }

  var requests: [Request] { state.withLock { $0.requests } }

  func respond(with responder: @escaping Responder) {
    state.withLock { $0.responder = responder }
  }

  func send(_ method: HTTPMethod, _ url: URL, body: Data?) async throws -> NMOSHTTPClientResponse {
    let request = Request(method: method, url: url, body: body)
    let responder = state.withLock { state in
      state.requests.append(request)
      return state.responder
    }
    return try responder(request)
  }
}
