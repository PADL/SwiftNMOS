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
@testable import NMOSClient
import Synchronization
import XCTest

private final class FakeHTTP: NMOSHTTPClient, Sendable {
  private struct State {
    var responses = [String: NMOSHTTPClientResponse]()
    var requests = [(HTTPMethod, URL, Data?)]()
  }

  private let state = Mutex(State())

  var responses: [String: NMOSHTTPClientResponse] {
    get { state.withLock { $0.responses } }
    set { state.withLock { $0.responses = newValue } }
  }

  var requests: [(HTTPMethod, URL, Data?)] { state.withLock { $0.requests } }

  func send(_ method: HTTPMethod, _ url: URL, body: Data?) async throws -> NMOSHTTPClientResponse {
    state.withLock {
      $0.requests.append((method, url, body))
      return $0.responses[url.absoluteString] ?? NMOSHTTPClientResponse(status: 404)
    }
  }
}

private let device = "002563da-2743-5213-af1e-3f2e096f0a9b"
private let flow = "28543b86-9d3b-5748-a677-af2b20d0ecdc"

private func sender(_ id: String, _ label: String = "out") -> String {
  """
  {"id":"\(id)","version":"1793440183:746857166","label":"\(label)","description":"",
   "tags":{},"flow_id":"\(flow)","transport":"urn:x-nmos:transport:rtp","device_id":"\(device)",
   "manifest_href":null,"interface_bindings":["en0"],
   "subscription":{"active":true,"receiver_id":null}}
  """
}

private let first = "d49fdb04-1090-57e0-a413-ff5e81d310b6"
private let second = "f41f70b9-a209-5070-8fe1-293309ff1761"

final class NMOSClientTests: XCTestCase {
  private let base = URL(string: "http://registry:8010")!

  func testALinkHeaderNamesItsPages() {
    let header = """
    <http://r/nodes?a=1>; rel="next", <http://r/nodes?a=2>; rel="prev"
    """
    XCTAssertEqual(NMOSQueryClient.link("prev", in: header)?.absoluteString, "http://r/nodes?a=2")
    XCTAssertNil(NMOSQueryClient.link("first", in: header))
  }

  func testResourcesFollowPagesBackAndSkipWhatTheyCannotRead() async throws {
    let http = FakeHTTP()
    let older = "http://registry:8010/x-nmos/query/v1.3/senders?page=2"
    http.responses["http://registry:8010/x-nmos/query/v1.3/senders?paging.limit=500"] =
      NMOSHTTPClientResponse(
        status: 200,
        body: Data("[\(sender(first)), {\"id\":\"not a sender\"}]".utf8),
        headers: ["link": "<\(older)>; rel=\"prev\""]
      )
    http.responses[older] = NMOSHTTPClientResponse(status: 200, body: Data("[\(sender(second))]".utf8))
    let client = NMOSQueryClient(baseURL: base, http: http)
    let senders = try await client.resources(NMOSSenderResource.self)
    XCTAssertEqual(senders.count, 2)
  }

  func testAnEventCarriesUpdatesAndRemovals() throws {
    let message = """
    {"grain":{"data":[
      {"path":"\(first)","pre":\(sender(first)),"post":\(sender(first, "new"))},
      {"path":"\(second)","pre":\(sender(second))},
      {"path":"\(second)","post":{"id":"video"}}
    ]}}
    """
    let event = try JSONDecoder().decode(
      NMOSQueryClient.Event<NMOSSenderResource>.self,
      from: Data(message.utf8)
    )
    XCTAssertEqual(event.changes.count, 2)
    guard case let .updated(updated) = event.changes[0] else { return XCTFail() }
    XCTAssertEqual(updated.label, "new")
    guard case let .removed(id) = event.changes[1] else { return XCTFail() }
    XCTAssertEqual(id.description, second)
  }

  func testTheMirrorHoldsWhatASubscriptionSends() async throws {
    let http = FakeHTTP()
    http.responses["http://registry:8010/x-nmos/query/v1.3/subscriptions"] =
      NMOSHTTPClientResponse(status: 201, body: Data(#"{"ws_href":"ws://r/s"}"#.utf8))
    let sync = """
    {"grain":{"data":[{"path":"\(first)","pre":\(sender(first)),"post":\(sender(first))}]}}
    """
    let client = NMOSQueryClient(baseURL: base, http: http) { _ in
      AsyncThrowingStream { continuation in
        // only the senders' subscription decodes this
        continuation.yield(Data(sync.utf8))
      }
    }
    let mirror = NMOSRegistryMirror(client: client)
    for await snapshot in mirror.snapshots() where !snapshot.senders.isEmpty {
      XCTAssertEqual(snapshot.senders.count, 1)
      break
    }
  }

  func testConnectingStagesTheSDPAndActivatesNow() async throws {
    let http = FakeHTTP()
    let id = try JSONDecoder().decode(NMOSID.self, from: Data("\"\(first)\"".utf8))
    let other = try JSONDecoder().decode(NMOSID.self, from: Data("\"\(second)\"".utf8))
    let api = URL(string: "http://node/x-nmos/connection/v1.1")!
    http.responses["http://node/x-nmos/connection/v1.1/single/receivers/\(first)/staged"] =
      NMOSHTTPClientResponse(status: 200)
    let client = NMOSConnectionClient(apiURL: api, http: http)
    try await client.connect(receiver: id, sender: other, sdp: "v=0")
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.0, .PATCH)
    let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.2)) as? [String: Any]
    XCTAssertEqual(body?["sender_id"] as? String, second)
    XCTAssertEqual(body?["master_enable"] as? Bool, true)
    let file = body?["transport_file"] as? [String: Any]
    XCTAssertEqual(file?["data"] as? String, "v=0")
    let activation = body?["activation"] as? [String: Any]
    XCTAssertEqual(activation?["mode"] as? String, "activate_immediate")
  }

  func testAStreamFromOutsideNMOSHasNoSender() async throws {
    let http = FakeHTTP()
    let id = try JSONDecoder().decode(NMOSID.self, from: Data("\"\(first)\"".utf8))
    let api = URL(string: "http://node/x-nmos/connection/v1.1")!
    http.responses["http://node/x-nmos/connection/v1.1/single/receivers/\(first)/staged"] =
      NMOSHTTPClientResponse(status: 200)
    try await NMOSConnectionClient(apiURL: api, http: http).connect(receiver: id, sdp: "v=0")
    let body = try JSONSerialization.jsonObject(
      with: XCTUnwrap(http.requests.first?.2)
    ) as? [String: Any]
    XCTAssertTrue(body?["sender_id"] is NSNull)
  }

  func testDisconnectingClearsTheTransportFile() async throws {
    let http = FakeHTTP()
    let id = try JSONDecoder().decode(NMOSID.self, from: Data("\"\(first)\"".utf8))
    let api = URL(string: "http://node/x-nmos/connection/v1.1")!
    http.responses["http://node/x-nmos/connection/v1.1/single/receivers/\(first)/staged"] =
      NMOSHTTPClientResponse(status: 200)
    try await NMOSConnectionClient(apiURL: api, http: http).disconnect(receiver: id)
    let body = try JSONSerialization.jsonObject(
      with: XCTUnwrap(http.requests.first?.2)
    ) as? [String: Any]
    XCTAssertEqual(body?["master_enable"] as? Bool, false)
    XCTAssertTrue((body?["transport_file"] as? [String: Any])?["data"] is NSNull)
  }

  func testAReceiverNotEnabledHasNoActiveStream() async throws {
    let http = FakeHTTP()
    let id = try JSONDecoder().decode(NMOSID.self, from: Data("\"\(first)\"".utf8))
    let url = "http://node/x-nmos/connection/v1.1/single/receivers/\(first)/active"
    http.responses[url] = NMOSHTTPClientResponse(
      status: 200,
      body: Data(#"{"master_enable":false,"transport_file":{"data":"v=0"}}"#.utf8)
    )
    let client = NMOSConnectionClient(
      apiURL: URL(string: "http://node/x-nmos/connection/v1.1")!,
      http: http
    )
    let active = try await client.activeTransportFile(receiver: id)
    XCTAssertNil(active)
  }

  func testRegistriesAreChosenByPriority() {
    func service(_ name: String, pri: String, ver: String = "v1.2,v1.3") -> NMOSDiscoveredService {
      NMOSDiscoveredService(
        name: name,
        host: "\(name).local.",
        port: 80,
        txt: ["pri": pri, "api_ver": ver, "api_proto": "http"]
      )
    }
    let urls = NMOSRegistryLocator.queryAPIs([
      service("b", pri: "100"),
      service("a", pri: "10"),
      service("old", pri: "1", ver: "v1.2"),
    ])
    XCTAssertEqual(urls.map(\.host), ["a.local.", "b.local."])
  }
}
