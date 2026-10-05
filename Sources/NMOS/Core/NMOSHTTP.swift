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

/// A failure an NMOS API reports to its client. Handlers throw it; the router turns it
/// into the status code and the `{code, error, debug}` body the specifications require.
public struct NMOSHTTPError: Error, Sendable, Equatable {
  public let status: HTTPStatusCode
  /// Suitable for showing to a user.
  public let message: String
  public let debug: String?

  public init(_ status: HTTPStatusCode, _ message: String, debug: String? = nil) {
    self.status = status
    self.message = message
    self.debug = debug
  }

  public static func badRequest(_ message: String, debug: String? = nil) -> Self {
    Self(.badRequest, message, debug: debug)
  }

  public static func notFound(_ message: String = "No such resource") -> Self {
    Self(.notFound, message)
  }

  public static func methodNotAllowed(_ method: HTTPMethod) -> Self {
    Self(.methodNotAllowed, "\(method.rawValue) is not supported on this resource")
  }

  public static func conflict(_ message: String) -> Self { Self(.conflict, message) }
  public static func locked(_ message: String) -> Self { Self(.locked, message) }
  public static func notImplemented(_ message: String) -> Self { Self(.notImplemented, message) }

  public static func internalError(_ message: String, debug: String? = nil) -> Self {
    Self(.internalServerError, message, debug: debug)
  }
}

private struct NMOSErrorBody: Encodable {
  let code: Int
  let error: String
  let debug: String?

  // debug is required by the schema, so it is written as null rather than left out
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(error, forKey: .error)
    try container.encode(debug, forKey: .debug)
  }

  private enum CodingKeys: String, CodingKey {
    case code, error, debug
  }
}

public extension HTTPResponse {
  /// A JSON response body, the representation every NMOS API must offer.
  static func nmos(
    json value: some Encodable,
    status: HTTPStatusCode = .ok,
    headers: HTTPHeaders = [:]
  ) throws -> HTTPResponse {
    var headers = headers
    headers[.contentType] = "application/json"
    return try HTTPResponse(statusCode: status, headers: headers, body: NMOSJSONCoding.encoder.encode(value))
  }

  static func nmos(error: NMOSHTTPError) -> HTTPResponse {
    let body = NMOSErrorBody(code: Int(error.status.code), error: error.message, debug: error.debug)
    return (try? nmos(json: body, status: error.status)) ?? HTTPResponse(statusCode: error.status)
  }
}

/// The permissive cross-origin headers IS-04 asks every response to carry, so that a
/// control interface served from elsewhere can use the APIs.
enum NMOSCORS {
  static let methods = "GET, PUT, POST, PATCH, HEAD, OPTIONS, DELETE"

  static func apply(to response: inout HTTPResponse, for request: HTTPRequest) {
    response.headers[HTTPHeader("Access-Control-Allow-Origin")] = "*"
    response.headers[HTTPHeader("Access-Control-Allow-Methods")] = methods
    response.headers[HTTPHeader("Access-Control-Allow-Headers")] =
      request.headers[HTTPHeader("Access-Control-Request-Headers")] ?? "Content-Type, Accept"
    response.headers[HTTPHeader("Access-Control-Max-Age")] = "3600"
  }
}
