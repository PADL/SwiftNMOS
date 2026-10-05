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

/// The response to a request the node made, to a Registration API for instance.
public struct NMOSHTTPClientResponse: Sendable {
  public var status: Int
  public var body: Data
  /// The response headers, keyed by lower-cased name.
  public var headers: [String: String]

  public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
    self.status = status
    self.body = body
    self.headers = headers
  }
}

/// How the node makes HTTP requests of its own. A failure to connect or a timeout is
/// thrown; any response, whatever its status, is returned.
public protocol NMOSHTTPClient: Sendable {
  /// `body` is sent as `application/json` when present.
  func send(_ method: HTTPMethod, _ url: URL, body: Data?) async throws -> NMOSHTTPClientResponse
}
