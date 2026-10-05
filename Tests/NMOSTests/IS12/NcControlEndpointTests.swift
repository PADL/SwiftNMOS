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
import FlyingSocks
import Foundation
import NMOS
import XCTest

/// The control endpoint as a node serves it.
final class NcControlEndpointTests: XCTestCase {
  func testTheEndpointUpgradesToAWebSocket() async throws {
    let node = NMOSNode(deviceModel: FixtureDeviceModel())
    let server = try HTTPServer(address: .inet(ip4: "127.0.0.1", port: 0))
    await node.attach(to: server)
    let serverTask = Task { try await server.run() }
    defer { serverTask.cancel() }
    try await server.waitUntilListening()
    guard case let .ip4(_, port) = await server.listeningAddress else {
      return XCTFail("the server is not listening on IPv4")
    }

    func get(_ path: String, headers: HTTPHeaders) async throws -> HTTPResponse {
      var client = HTTPClient()
      var headers = headers
      headers[.host] = "127.0.0.1"
      let request = HTTPRequest(
        method: .GET, version: .http11, path: path, query: [],
        headers: headers, body: HTTPBodySequence(data: Data())
      )
      return try await client.sendHTTPRequest(request, to: .inet(ip4: "127.0.0.1", port: port))
    }

    let listing = try await get("/x-nmos/ncp/", headers: [:])
    let children = try await JSONDecoder().decode([String].self, from: listing.bodyData)
    XCTAssertEqual(children, ["v1.0/"])

    let upgrade = try await get("/x-nmos/ncp/v1.0", headers: [
      .upgrade: "websocket", .connection: "Upgrade", .webSocketVersion: "13",
      .webSocketKey: Data(repeating: 7, count: 16).base64EncodedString(),
    ])
    XCTAssertEqual(upgrade.statusCode, .switchingProtocols)
    XCTAssertEqual(upgrade.headers[.upgrade], "websocket")
    await server.stop()
  }

  func testThereIsNoEndpointWithoutADeviceModel() async throws {
    let node = NMOSNode()
    let server = try HTTPServer(address: .inet(ip4: "127.0.0.1", port: 0))
    await node.attach(to: server)
    let response = try await node.router.handleRequest(HTTPRequest(
      method: .GET, version: .http11, path: "/x-nmos/ncp/v1.0", query: [],
      headers: [:], body: HTTPBodySequence(data: Data())
    ))
    XCTAssertEqual(response.statusCode, .notFound)
  }
}
