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
import XCTest

final class NMOSRouterTests: XCTestCase {
  private var router: NMOSRouter!

  override func setUp() async throws {
    router = NMOSRouter()
    await router.add(.GET, "node/v1.3/self") { _ in try .nmos(json: ["id": "self"]) }
    await router.add(.GET, "node/v1.3/devices") { _ in try .nmos(json: [String]()) }
    await router.add(.GET, "node/v1.3/devices/{deviceId}") { request in
      try .nmos(json: ["id": request.parameters["deviceId"] ?? ""])
    }
    await router.add(.GET, "connection/v1.1/single/senders/{senderId}/staged") { _ in
      try .nmos(json: ["staged": true])
    }
    await router.add(.PATCH, "connection/v1.1/single/senders/{senderId}/staged") { request in
      let body: [String: Bool] = try await request.body()
      return try .nmos(json: body)
    }
    await router.add(.GET, "node/v1.3/devices/first") { _ in try .nmos(json: ["id": "literal"]) }
    await router.add(.GET, "node/v1.3/broken") { _ in throw CancellationError() }
    await router.add(.GET, "node/v1.3/refused") { _ in throw NMOSHTTPError.locked("busy") }
  }

  private func send(
    _ method: HTTPMethod,
    _ path: String,
    headers: HTTPHeaders = [:],
    body: String = ""
  ) async throws -> (response: HTTPResponse, json: NMOSJSONValue?) {
    let request = HTTPRequest(
      method: method, version: .http11, path: path, query: [], headers: headers,
      body: HTTPBodySequence(data: Data(body.utf8))
    )
    let response = try await router.handleRequest(request)
    let data = try await response.bodyData
    return (response, data.isEmpty ? nil : try NMOSJSONValue(data: data))
  }

  func testListsTheChildrenOfEachLevel() async throws {
    let root = try await send(.GET, "/x-nmos")
    XCTAssertEqual(root.json, ["connection/", "node/"])
    XCTAssertEqual(root.response.headers[.contentType], "application/json")
    let api = try await send(.GET, "/x-nmos/node/")
    XCTAssertEqual(api.json, ["v1.3/"])
    let version = try await send(.GET, "/x-nmos/node/v1.3/")
    XCTAssertEqual(version.json, ["broken/", "devices/", "refused/", "self/"])
    // a level whose children are all placeholders lists nothing of its own
    let senders = try await send(.GET, "/x-nmos/connection/v1.1/single/senders")
    XCTAssertEqual(senders.response.statusCode, .notFound)
  }

  func testAcceptsEitherTrailingSlashForm() async throws {
    for path in ["/x-nmos/node/v1.3/self", "/x-nmos/node/v1.3/self/"] {
      let result = try await send(.GET, path)
      XCTAssertEqual(result.response.statusCode, .ok)
      XCTAssertEqual(result.json, ["id": "self"])
    }
  }

  func testBindsPlaceholdersAndPrefersLiterals() async throws {
    let parameter = try await send(.GET, "/x-nmos/node/v1.3/devices/abc")
    XCTAssertEqual(parameter.json, ["id": "abc"])
    let literal = try await send(.GET, "/x-nmos/node/v1.3/devices/first")
    XCTAssertEqual(literal.json, ["id": "literal"])
  }

  func testUnknownPathsAreJSONErrors() async throws {
    let result = try await send(.GET, "/x-nmos/node/v9.9/self")
    XCTAssertEqual(result.response.statusCode, .notFound)
    XCTAssertEqual(result.json?["code"], 404)
    XCTAssertNotNil(result.json?["error"]?.stringValue)
    XCTAssertEqual(result.json?["debug"], .null)
  }

  func testUnsupportedMethodsAreRefusedWithAllow() async throws {
    let result = try await send(.DELETE, "/x-nmos/node/v1.3/self")
    XCTAssertEqual(result.response.statusCode, .methodNotAllowed)
    XCTAssertEqual(result.response.headers[HTTPHeader("Allow")], "GET, HEAD, OPTIONS")
    XCTAssertEqual(result.json?["code"], 405)
  }

  func testAnswersPreflightRequests() async throws {
    let result = try await send(
      .OPTIONS, "/x-nmos/connection/v1.1/single/senders/abc/staged",
      headers: [HTTPHeader("Access-Control-Request-Headers"): "Content-Type, Authorization"]
    )
    XCTAssertEqual(result.response.statusCode, .ok)
    XCTAssertEqual(result.response.headers[HTTPHeader("Allow")], "GET, HEAD, OPTIONS, PATCH")
    XCTAssertEqual(result.response.headers[HTTPHeader("Access-Control-Allow-Origin")], "*")
    XCTAssertEqual(
      result.response.headers[HTTPHeader("Access-Control-Allow-Headers")], "Content-Type, Authorization"
    )
  }

  func testEveryResponseCarriesCORSHeaders() async throws {
    for path in ["/x-nmos/node/v1.3/self", "/x-nmos/nowhere", "/x-nmos/node/v1.3/broken"] {
      let result = try await send(.GET, path)
      XCTAssertEqual(result.response.headers[HTTPHeader("Access-Control-Allow-Origin")], "*", path)
      XCTAssertNotNil(result.response.headers[HTTPHeader("Access-Control-Allow-Methods")], path)
    }
  }

  func testHeadIsGetWithoutABody() async throws {
    let result = try await send(.HEAD, "/x-nmos/node/v1.3/self")
    XCTAssertEqual(result.response.statusCode, .ok)
    XCTAssertEqual(result.response.headers[.contentType], "application/json")
    XCTAssertNil(result.json)
  }

  func testDecodesRequestBodies() async throws {
    let path = "/x-nmos/connection/v1.1/single/senders/abc/staged"
    let good = try await send(.PATCH, path, body: #"{"master_enable":true}"#)
    XCTAssertEqual(good.json, ["master_enable": true])
    let bad = try await send(.PATCH, path, body: "{")
    XCTAssertEqual(bad.response.statusCode, .badRequest)
    XCTAssertEqual(bad.json?["code"], 400)
    XCTAssertNotNil(bad.json?["debug"]?.stringValue)
  }

  func testHandlerErrorsBecomeErrorBodies() async throws {
    let refused = try await send(.GET, "/x-nmos/node/v1.3/refused")
    XCTAssertEqual(refused.response.statusCode, .locked)
    XCTAssertEqual(refused.json?["error"], "busy")
    let broken = try await send(.GET, "/x-nmos/node/v1.3/broken")
    XCTAssertEqual(broken.response.statusCode, .internalServerError)
    XCTAssertEqual(broken.json?["code"], 500)
  }
}
