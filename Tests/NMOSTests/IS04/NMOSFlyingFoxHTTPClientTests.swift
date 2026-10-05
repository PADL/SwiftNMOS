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
@testable import NMOS
import XCTest

/// The node's own HTTP client against a real server, as it reaches a Registration API.
final class NMOSFlyingFoxHTTPClientTests: XCTestCase {
  private var server: HTTPServer!
  private var serverTask: Task<Void, any Error>!
  private var port: UInt16 = 0

  override func setUp() async throws {
    let server = try HTTPServer(address: .inet(ip4: "127.0.0.1", port: 0))
    await server.appendRoute("POST /x-nmos/registration/v1.3/resource") { request in
      // answers with what it was sent, so the test can see the request arrived whole
      let body = try await request.bodyData
      let type = request.headers[.contentType] ?? ""
      return HTTPResponse(
        statusCode: .created,
        headers: [HTTPHeader("Location"): "/there", HTTPHeader("X-Content-Type"): type],
        body: body
      )
    }
    await server.appendRoute("DELETE /gone") { _ in HTTPResponse(statusCode: .noContent) }
    await server.appendRoute("GET /slow") { _ in
      try await Task.sleep(for: .seconds(5))
      return HTTPResponse(statusCode: .ok)
    }
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

  private func url(_ path: String, host: String = "127.0.0.1") throws -> URL {
    try XCTUnwrap(URL(string: "http://\(host):\(port)\(path)"))
  }

  func testSendsABodyAsJSONAndReturnsTheResponse() async throws {
    let client = NMOSFlyingFoxHTTPClient()
    let body = Data(#"{"type":"node"}"#.utf8)
    let response = try await client.send(.POST, url("/x-nmos/registration/v1.3/resource"), body: body)
    XCTAssertEqual(response.status, 201)
    XCTAssertEqual(response.body, body)
    XCTAssertEqual(response.headers["location"], "/there")
    XCTAssertEqual(response.headers["x-content-type"], "application/json")
  }

  func testReturnsAnyStatusAndAnEmptyBody() async throws {
    let client = NMOSFlyingFoxHTTPClient()
    let gone = try await client.send(.DELETE, url("/gone"), body: nil)
    XCTAssertEqual(gone.status, 204)
    XCTAssertEqual(gone.body, Data())
    let missing = try await client.send(.DELETE, url("/missing"), body: nil)
    XCTAssertEqual(missing.status, 404)
  }

  func testResolvesAHostName() async throws {
    let client = NMOSFlyingFoxHTTPClient()
    let response = try await client.send(.DELETE, url("/gone", host: "localhost"), body: nil)
    XCTAssertEqual(response.status, 204)
  }

  func testAPortOutOfRangeIsAnUnsupportedURL() async throws {
    let client = NMOSFlyingFoxHTTPClient()
    let bad = try XCTUnwrap(URL(string: "http://registry:80100/x-nmos/registration/v1.3/health"))
    do {
      _ = try await client.send(.GET, bad, body: nil)
      XCTFail("a port above 65535 cannot be requested")
    } catch {
      XCTAssertEqual(error as? NMOSHTTPClientError, .unsupportedURL(bad))
    }
  }

  func testThrowsWhenTheServerTakesTooLong() async throws {
    let client = NMOSFlyingFoxHTTPClient(timeout: .milliseconds(100))
    do {
      _ = try await client.send(.GET, url("/slow"), body: nil)
      XCTFail("the request cannot have been answered")
    } catch {
      XCTAssertEqual(error as? NMOSHTTPClientError, .timedOut)
    }
  }

  func testTheTimeoutCoversLookingUpTheName() async throws {
    // a resolver that takes far longer than the request is allowed
    let client = NMOSFlyingFoxHTTPClient(timeout: .milliseconds(100)) { host, _ in
      Thread.sleep(forTimeInterval: 2)
      throw NMOSHTTPClientError.unresolvedHost(host)
    }
    let started = ContinuousClock.now
    do {
      _ = try await client.send(.GET, url("/gone", host: "registry.invalid"), body: nil)
      XCTFail("the name cannot have resolved")
    } catch {
      XCTAssertEqual(error as? NMOSHTTPClientError, .timedOut)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
  }

  func testLookingUpANameDoesNotHoldTheThreadsThatRunTasks() async throws {
    // more blocked lookups than there are threads to run tasks on
    let client = NMOSFlyingFoxHTTPClient(timeout: .seconds(5)) { host, _ in
      Thread.sleep(forTimeInterval: 1)
      throw NMOSHTTPClientError.unresolvedHost(host)
    }
    let url = try url("/gone", host: "registry.invalid")
    let requests = (0..<ProcessInfo.processInfo.activeProcessorCount * 2).map { _ in
      Task { try? await client.send(.GET, url, body: nil) }
    }
    try await Task.sleep(for: .milliseconds(100))

    // other work goes on meanwhile
    let started = ContinuousClock.now
    await Task.detached { await Task.yield() }.value
    XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))

    for request in requests {
      let response = await request.value
      XCTAssertNil(response)
    }
  }

  func testTriesEachAddressANameResolvesTo() async throws {
    // as localhost often resolves: IPv6 first, where nothing listens here
    let port = port
    let client = NMOSFlyingFoxHTTPClient(timeout: .seconds(2)) { _, _ in
      [try .ip6(.inet6(ip6: "::1", port: port)), try .ip4(.inet(ip4: "127.0.0.1", port: port))]
    }
    let response = try await client.send(.DELETE, url("/gone", host: "registry"), body: nil)
    XCTAssertEqual(response.status, 204)
  }

  func testUsesAnAddressLiteralWithoutLookingItUp() async throws {
    let client = NMOSFlyingFoxHTTPClient(timeout: .seconds(1)) { host, _ in
      XCTFail("looked up \(host)")
      throw NMOSHTTPClientError.unresolvedHost(host)
    }
    let response = try await client.send(.DELETE, url("/gone"), body: nil)
    XCTAssertEqual(response.status, 204)
  }

  func testThrowsWhenNothingIsListening() async throws {
    await server.stop()
    let client = NMOSFlyingFoxHTTPClient(timeout: .seconds(1))
    do {
      _ = try await client.send(.GET, url("/gone"), body: nil)
      XCTFail("nothing is listening")
    } catch {}
  }

  func testRefusesWhatItCannotSpeak() async throws {
    let client = NMOSFlyingFoxHTTPClient()
    let url = try XCTUnwrap(URL(string: "https://registry.example/x-nmos"))
    do {
      _ = try await client.send(.GET, url, body: nil)
      XCTFail("https is not supported")
    } catch {
      XCTAssertEqual(error as? NMOSHTTPClientError, .unsupportedURL(url))
    }
  }
}
