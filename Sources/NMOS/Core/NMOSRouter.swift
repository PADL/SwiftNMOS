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
import Logging

/// A request to an NMOS API, with the values of the `{placeholders}` in its route.
public struct NMOSRequest: Sendable {
  public let http: HTTPRequest
  public let parameters: [String: String]

  /// The placeholder as a resource ID; a malformed one names nothing, hence not found.
  public func id(_ name: String) throws -> NMOSID {
    guard let value = parameters[name], let id = NMOSID(value) else { throw NMOSHTTPError.notFound() }
    return id
  }

  /// The request body decoded from JSON; a body that does not decode is a bad request.
  public func body<T: Decodable>(_ type: T.Type = T.self) async throws -> T {
    do {
      return try await JSONDecoder().decode(type, from: http.bodyData)
    } catch {
      throw NMOSHTTPError.badRequest("The request body is not valid", debug: "\(error)")
    }
  }
}

public typealias NMOSRouteHandler = @Sendable (NMOSRequest) async throws -> HTTPResponse

/// Serves everything under `/x-nmos/`. The APIs register their routes here rather than
/// with the HTTP server, so that the behaviour the specifications share is in one place:
/// the listing at each level, either trailing-slash form, CORS, and JSON error bodies.
public actor NMOSRouter: HTTPHandler {
  public static let root = "x-nmos"

  private struct Route {
    let method: HTTPMethod
    let pattern: [Substring]
    let handler: NMOSRouteHandler
  }

  private var routes = [Route]()
  private var isRegistering = false
  private let logger: Logger

  public init(logger: Logger = Logger(label: "com.padl.NMOS.Router")) {
    self.logger = logger
  }

  /// True the first time it is asked, for an owner that adds its routes once however
  /// many HTTP servers the router is then attached to.
  func beginRegistering() -> Bool {
    defer { isRegistering = true }
    return !isRegistering
  }

  /// Adds a route. `pattern` is relative to `/x-nmos/`, such as
  /// `node/v1.3/devices/{deviceId}`; a component in braces matches any value.
  public func add(_ method: HTTPMethod, _ pattern: String, handler: @escaping NMOSRouteHandler) {
    routes.append(Route(method: method, pattern: Self.components(pattern), handler: handler))
  }

  /// Hands this router every request under `/x-nmos/` that reaches the HTTP server.
  public nonisolated func attach(to registrar: some NMOSRouteRegistrar) async {
    let methods: Set<HTTPMethod> = [.GET, .HEAD, .OPTIONS, .POST, .PUT, .PATCH, .DELETE]
    await registrar.appendRoute(HTTPRoute(methods: methods, path: "/\(Self.root)"), to: self)
    await registrar.appendRoute(HTTPRoute(methods: methods, path: "/\(Self.root)/*"), to: self)
  }

  public func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
    var response: HTTPResponse
    do {
      response = try await route(request)
    } catch let error as NMOSHTTPError {
      response = .nmos(error: error)
    } catch {
      logger.warning("\(request.method.rawValue) \(request.path) failed: \(error)")
      response = .nmos(error: .internalError("The request could not be completed", debug: "\(error)"))
    }
    NMOSCORS.apply(to: &response, for: request)
    if request.method == .HEAD {
      response = HTTPResponse(statusCode: response.statusCode, headers: response.headers)
    }
    return response
  }

  private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
    // splitting drops empty components, which is what admits a trailing slash
    let components = Self.components(request.path)
    guard components.first == Self.root[...] else { throw NMOSHTTPError.notFound() }
    let path = Array(components.dropFirst())

    let method = request.method == .HEAD ? HTTPMethod.GET : request.method
    let matches: [(route: Route, parameters: [String: String])] = routes.compactMap { route in
      Self.match(route.pattern, path).map { (route, $0) }
    }
    // a literal component is a closer match than a placeholder
    let best = matches.filter { $0.route.method == method }
      .min { $0.parameters.count < $1.parameters.count }
    if let best {
      return try await best.route.handler(NMOSRequest(http: request, parameters: best.parameters))
    }

    let children = children(of: path)
    var allowed = Set(matches.map(\.route.method))
    if !children.isEmpty { allowed.insert(.GET) }
    guard !allowed.isEmpty else { throw NMOSHTTPError.notFound() }
    if method == .OPTIONS {
      var response = HTTPResponse(statusCode: .ok)
      response.headers[HTTPHeader("Allow")] = Self.allow(allowed)
      return response
    }
    guard method == .GET, !children.isEmpty else {
      var response = HTTPResponse.nmos(error: .methodNotAllowed(request.method))
      response.headers[HTTPHeader("Allow")] = Self.allow(allowed)
      return response
    }
    return try .nmos(json: children)
  }

  /// What a level with no handler of its own lists: the next fixed component of every
  /// route below it, each with a trailing slash.
  private func children(of path: [Substring]) -> [String] {
    let children = routes.compactMap { route -> String? in
      guard route.pattern.count > path.count,
            Self.match(Array(route.pattern.prefix(path.count)), path) != nil else { return nil }
      let next = route.pattern[path.count]
      return Self.isPlaceholder(next) ? nil : "\(next)/"
    }
    return Set(children).sorted()
  }

  private static func components(_ path: String) -> [Substring] {
    path.split(separator: "/", omittingEmptySubsequences: true)
  }

  private static func isPlaceholder(_ component: Substring) -> Bool {
    component.hasPrefix("{") && component.hasSuffix("}")
  }

  private static func match(_ pattern: [Substring], _ path: [Substring]) -> [String: String]? {
    guard pattern.count == path.count else { return nil }
    var parameters = [String: String]()
    for (component, value) in zip(pattern, path) {
      if isPlaceholder(component) {
        parameters[String(component.dropFirst().dropLast())] = String(value)
      } else if component != value {
        return nil
      }
    }
    return parameters
  }

  private static func allow(_ methods: Set<HTTPMethod>) -> String {
    var methods = methods.union([.OPTIONS])
    if methods.contains(.GET) { methods.insert(.HEAD) }
    return methods.map(\.rawValue).sorted().joined(separator: ", ")
  }
}
