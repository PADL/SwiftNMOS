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

/// The node's APIs through a real HTTP server, as a controller reaches them.
final class NMOSNodeAPITests: XCTestCase {
  private var node: NMOSNode!
  private var server: HTTPServer!
  private var serverTask: Task<Void, any Error>!
  private var port: UInt16 = 0

  override func setUp() async throws {
    node = NMOSNode(
      connectionProvider: FixtureConnectionProvider(),
      deviceModel: FixtureDeviceModel(),
      discovery: FixtureServiceDiscovery(),
      httpClient: FixtureHTTPClient()
    )
    let server = try HTTPServer(address: .inet(ip4: "127.0.0.1", port: 0))
    await node.attach(to: server)
    // a catch-all appended afterwards, as the host's web user interface is
    await server.appendRoute("GET /*") { _ in HTTPResponse(statusCode: .ok, body: Data("ui".utf8)) }
    serverTask = Task { try await server.run() }
    try await server.waitUntilListening()
    guard case let .ip4(_, port) = await server.listeningAddress else {
      return XCTFail("the server is not listening on IPv4")
    }
    self.port = port
    self.server = server
  }

  override func tearDown() async throws {
    await server?.stop()
    serverTask?.cancel()
  }

  private func get(
    _ path: String,
    method: HTTPMethod = .GET
  ) async throws -> (status: HTTPStatusCode, body: Data, headers: HTTPHeaders) {
    var client = HTTPClient()
    let request = HTTPRequest(
      method: method, version: .http11, path: path, query: [],
      headers: [.host: "127.0.0.1"], body: HTTPBodySequence(data: Data())
    )
    let response = try await client.sendHTTPRequest(request, to: .inet(ip4: "127.0.0.1", port: port))
    return try await (response.statusCode, response.bodyData, response.headers)
  }

  func testServesTheListingAtEachLevel() async throws {
    for (path, children) in [
      ("/x-nmos", ["connection/", "ncp/", "node/"]), ("/x-nmos/", ["connection/", "ncp/", "node/"]),
      ("/x-nmos/node/", ["v1.3/"]),
      ("/x-nmos/node/v1.3", ["devices/", "flows/", "receivers/", "self/", "senders/", "sources/"]),
    ] {
      let response = try await get(path)
      XCTAssertEqual(response.status, .ok, path)
      XCTAssertEqual(try JSONDecoder().decode([String].self, from: response.body), children, path)
      XCTAssertEqual(response.headers[HTTPHeader("Access-Control-Allow-Origin")], "*", path)
    }
  }

  func testServesTheNodeOnceItIsDescribed() async throws {
    let before = try await get("/x-nmos/node/v1.3/self")
    XCTAssertEqual(before.status, .serviceUnavailable)
    XCTAssertEqual(try NMOSJSONValue(data: before.body)["code"], 503)

    let described = NMOSNodeResource(
      id: NMOSID(UUID()), label: "MonitorTwo", description: "Lukktone MonitorTwo",
      href: "http://127.0.0.1:\(port)/", hostname: "monitortwo",
      api: .init(versions: [.v1_3], endpoints: [.init(host: "127.0.0.1", port: Int(port))]),
      clocks: [.internal(name: "clk0")]
    )
    let version = await node.store.upsert(.node(described))

    let after = try await get("/x-nmos/node/v1.3/self/")
    XCTAssertEqual(after.status, .ok)
    let served = try JSONDecoder().decode(NMOSNodeResource.self, from: after.body)
    XCTAssertEqual(served.id, described.id)
    XCTAssertEqual(served.version, version)
    XCTAssertEqual(served.label, "MonitorTwo")
    XCTAssertEqual(served.clocks, [.internal(name: "clk0")])
  }

  func testServesEachCollectionAndItsResources() async throws {
    let resources = FixtureResources()
    for collection in ["devices", "sources", "flows", "senders", "receivers"] {
      let empty = try await get("/x-nmos/node/v1.3/\(collection)")
      XCTAssertEqual(try NMOSJSONValue(data: empty.body), [], collection)
    }
    await node.store.reconcile(resources.all, replacing: Set(NMOSResourceKind.allCases))

    for resource in resources.all where resource.kind != .node {
      let collection = resource.kind.collection
      let stored = await node.store.resource(resource.kind, id: resource.id)
      let expected = try NMOSJSONValue(encoding: stored)

      // the collection holds the resource, and either form of its own path serves it
      let listed = try await get("/x-nmos/node/v1.3/\(collection)/")
      XCTAssertEqual(try NMOSJSONValue(data: listed.body), [expected], collection)
      for path in ["/x-nmos/node/v1.3/\(collection)/\(resource.id)", "/x-nmos/node/v1.3/\(collection)/\(resource.id)/"] {
        let single = try await get(path)
        XCTAssertEqual(single.status, .ok, path)
        XCTAssertEqual(single.headers[.contentType], "application/json", path)
        XCTAssertEqual(try NMOSJSONValue(data: single.body), expected, path)
      }
    }
  }

  func testAnUnknownResourceIsNotFound() async throws {
    let resources = FixtureResources()
    await node.store.reconcile(resources.all, replacing: Set(NMOSResourceKind.allCases))
    // a sender's ID names no receiver, and a malformed ID names nothing
    for path in [
      "/x-nmos/node/v1.3/receivers/\(resources.sender)", "/x-nmos/node/v1.3/senders/\(NMOSID(UUID()))",
      "/x-nmos/node/v1.3/devices/not-an-id", "/x-nmos/node/v1.3/nodes",
    ] {
      let response = try await get(path)
      XCTAssertEqual(response.status, .notFound, path)
      let body = try NMOSJSONValue(data: response.body)
      XCTAssertEqual(body["code"], 404, path)
      XCTAssertNotNil(body["error"]?.stringValue, path)
      XCTAssertNotNil(body["debug"], path)
    }
  }

  func testDeclinesTheDeprecatedReceiverTarget() async throws {
    let resources = FixtureResources()
    await node.store.reconcile(resources.all, replacing: Set(NMOSResourceKind.allCases))
    let target = "/x-nmos/node/v1.3/receivers/\(resources.receiver)/target"

    let put = try await get(target, method: .PUT)
    XCTAssertEqual(put.status, .notImplemented)
    XCTAssertEqual(try NMOSJSONValue(data: put.body)["code"], 501)

    let options = try await get(target, method: .OPTIONS)
    XCTAssertEqual(options.status, .ok)
    XCTAssertEqual(options.headers[HTTPHeader("Access-Control-Allow-Methods")]?.contains("PUT"), true)

    let unknown = try await get("/x-nmos/node/v1.3/receivers/\(NMOSID(UUID()))/target", method: .PUT)
    XCTAssertEqual(unknown.status, .notFound)

    // the collections themselves are read-only
    let post = try await get("/x-nmos/node/v1.3/receivers", method: .POST)
    XCTAssertEqual(post.status, .methodNotAllowed)
  }

  func testServesFromEveryServerItIsAttachedTo() async throws {
    // a host that listens in two places attaches the node to both
    let second = try HTTPServer(address: .inet(ip4: "127.0.0.1", port: 0))
    await node.attach(to: second)
    let running = Task { try await second.run() }
    defer { running.cancel() }
    try await second.waitUntilListening()
    guard case let .ip4(_, secondPort) = await second.listeningAddress else {
      return XCTFail("the server is not listening on IPv4")
    }

    let first = try await get("/x-nmos/node/v1.3")
    var client = HTTPClient()
    let request = HTTPRequest(
      method: .GET, version: .http11, path: "/x-nmos/node/v1.3", query: [],
      headers: [.host: "127.0.0.1"], body: HTTPBodySequence(data: Data())
    )
    let response = try await client.sendHTTPRequest(request, to: .inet(ip4: "127.0.0.1", port: secondPort))
    XCTAssertEqual(response.statusCode, .ok)
    let body = try await response.bodyData
    XCTAssertEqual(body, first.body)
  }

  func testLeavesOtherPathsToTheHost() async throws {
    let response = try await get("/index.html")
    XCTAssertEqual(response.status, .ok)
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "ui")
  }

  func testRunEndsWhenCancelled() async throws {
    let running = Task { [node] in try await node!.run() }
    try await Task.sleep(for: .milliseconds(50))
    running.cancel()
    do {
      try await running.value
      XCTFail("run returns only by being cancelled")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }
}
