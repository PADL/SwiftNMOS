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
import XCTest

/// Registered operation: what the node says to a Registration API, and what it does
/// about each answer IS-04 "Behaviour: Registration" describes.
final class NMOSRegistrationTests: XCTestCase {
  private let resources = FixtureResources()
  private let registry = FixtureRegistry()
  private let discovery = FixtureServiceDiscovery()
  private var store: NMOSResourceStore!
  private var running: Task<Void, any Error>?

  private static let heartbeat = Duration.milliseconds(40)

  override func setUp() async throws {
    store = NMOSResourceStore()
  }

  override func tearDown() async throws {
    await stop()
  }

  private func start(
    registryURL: URL? = URL(string: "http://registry:8010"),
    backoff: ClosedRange<Duration> = .milliseconds(20)...(.milliseconds(80)),
    httpClient: (any NMOSHTTPClient)? = nil
  ) {
    let node = NMOSNode(
      configuration: .init(
        registryURL: registryURL, heartbeatInterval: Self.heartbeat, registrationBackoff: backoff
      ),
      store: store, discovery: discovery, httpClient: httpClient ?? registry.client
    )
    running = Task { try await node.run() }
  }

  private func stop() async {
    running?.cancel()
    _ = await running?.result
    running = nil
  }

  private func describe() async {
    await store.reconcile(resources.all, replacing: Set(NMOSResourceKind.allCases))
  }

  private func registrations(_ registry: String = "registry:8010") -> [String] {
    self.registry.calls(to: registry).filter { $0.method == .POST && $0.path == "resource" }.compactMap(\.type)
  }

  private func heartbeats(_ registry: String = "registry:8010") -> Int {
    self.registry.calls(to: registry).count { $0.path.hasPrefix("health/") }
  }

  private func service(_ host: String, pri: String, ver: String = "v1.2,v1.3", proto: String = "http",
                       auth: String = "false") -> NMOSDiscoveredService
  {
    .init(name: host, host: host, port: 8010,
          txt: ["api_ver": ver, "api_proto": proto, "api_auth": auth, "pri": pri])
  }

  func testRegistersEveryResourceParentsFirst() async throws {
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
    XCTAssertEqual(registrations(), ["node", "device", "source", "flow", "sender", "receiver"])

    // the request is the resource as the Node API serves it, wrapped with its type
    let request = try XCTUnwrap(registry.client.requests.first)
    XCTAssertEqual(request.url.absoluteString, "http://registry:8010/x-nmos/registration/v1.3/resource")
    let body = try NMOSJSONValue(data: XCTUnwrap(request.body))
    XCTAssertEqual(body["type"], "node")
    let node = await store.node
    XCTAssertEqual(body["data"], try NMOSJSONValue(encoding: node))
  }

  func testWaitsForTheNodeToBeDescribed() async throws {
    start()
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(registry.calls, [])
    await describe()
    await eventually("the node is registered") { registry.holds("node", resources.node) }
  }

  func testHeartbeatsAtTheInterval() async throws {
    await describe()
    start()
    await eventually("three heartbeats are sent") { heartbeats() >= 3 }
    let health = try XCTUnwrap(registry.calls.first { $0.path.hasPrefix("health/") })
    XCTAssertEqual(health.method, .POST)
    XCTAssertEqual(health.path, "health/nodes/\(resources.node)")
    // nothing is registered twice for want of a change
    XCTAssertEqual(registrations().count, 6)
  }

  func testHeartbeatsWhileResourcesAreStillBeingRegistered() async throws {
    // a registry that takes two heartbeat intervals over each resource, and collects a
    // node it has not heard from for five, as a real one does after 12 seconds
    let collection = Duration.milliseconds(200)
    let lastHeard = Mutex(ContinuousClock.now)
    registry.override { [registry] call in
      let silence = lastHeard.withLock { ContinuousClock.now - $0 }
      if silence > collection { registry.forget() }
      if call.path.hasPrefix("health/") || call.type == "node" { lastHeard.withLock { $0 = .now } }
      return nil
    }
    await describe()
    start(httpClient: SlowRegistrationClient(client: registry.client, delay: .milliseconds(80)))
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }

    // the node stayed registered throughout: nothing had to be registered twice
    XCTAssertEqual(registrations(), ["node", "device", "source", "flow", "sender", "receiver"])
    let calls = registry.calls
    let firstHeartbeat = try XCTUnwrap(calls.firstIndex { $0.path.hasPrefix("health/") })
    let lastRegistration = try XCTUnwrap(calls.lastIndex { $0.type == "receiver" })
    XCTAssertLessThan(firstHeartbeat, lastRegistration)
    XCTAssertTrue(registry.holds("node", resources.node))
  }

  func testAStaleRecordIsClearedBeforeRegistering() async throws {
    registry.remember("node", resources.node)
    registry.remember("sender", NMOSID(UUID()))
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
    let calls = registry.calls.prefix(3).map { "\($0.method.rawValue) \($0.path)" }
    XCTAssertEqual(calls, ["POST resource", "DELETE resource/nodes/\(resources.node)", "POST resource"])
    XCTAssertEqual(registrations(), ["node", "node", "device", "source", "flow", "sender", "receiver"])
  }

  func testRegistersAgainWhenTheRegistryForgetsTheNode() async throws {
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
    registry.forget()
    await eventually("everything is registered again") { registrations().count == 12 }
    XCTAssertEqual(Array(registrations().suffix(6)), ["node", "device", "source", "flow", "sender", "receiver"])
    XCTAssertTrue(registry.holds("receiver", resources.receiver))
  }

  func testObservesChangesToTheStore() async throws {
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }

    var sender = resources.senderResource
    sender.subscription.active = true
    await store.upsert(.sender(sender))
    await eventually("the sender is registered again") { registrations().count == 7 }
    XCTAssertEqual(registrations().last, "sender")

    // a sender goes before the flow it refers to, and the flow before its source
    await store.reconcile(
      resources.all.filter { [.node, .device, .receiver].contains($0.kind) },
      replacing: Set(NMOSResourceKind.allCases)
    )
    await eventually("the source is removed") { !registry.holds("source", resources.source) }
    let removals = registry.calls.filter { $0.method == .DELETE }.map(\.path)
    XCTAssertEqual(removals, [
      "resource/senders/\(resources.sender)", "resource/flows/\(resources.flow)",
      "resource/sources/\(resources.source)",
    ])
  }

  func testARefusedResourceIsNotOfferedAgainUnchanged() async throws {
    registry.override { call in call.type == "sender" ? .init(status: 400) : nil }
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
    await eventually("heartbeats continue") { heartbeats() >= 3 }
    XCTAssertEqual(registrations().count { $0 == "sender" }, 1)

    // corrected, it is offered again
    registry.override(nil)
    var sender = resources.senderResource
    sender.label = "corrected"
    await store.upsert(.sender(sender))
    await eventually("the sender is registered") { registry.holds("sender", resources.sender) }
  }

  func testAConflictingAPIVersionIsUnregisteredFirst() async throws {
    let location = "/x-nmos/registration/v1.2/resource/nodes/\(resources.node)"
    let conflicted = Mutex(false)
    registry.override { call in
      if call.method == .DELETE { return nil }
      guard call.type == "node", !conflicted.withLock({ $0 }) else { return nil }
      conflicted.withLock { $0 = true }
      return .init(status: 409, headers: ["location": location])
    }
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
    let requests = registry.client.requests.prefix(3).map { "\($0.method.rawValue) \($0.url.path)" }
    XCTAssertEqual(requests, [
      "POST /x-nmos/registration/v1.3/resource", "DELETE \(location)",
      "POST /x-nmos/registration/v1.3/resource",
    ])
  }

  func testChoosesTheRegistryByPriorityAndWhatItOffers() async throws {
    await describe()
    start(registryURL: nil)
    discovery.publish([
      service("old", pri: "0", ver: "v1.1,v1.2"),
      service("secure", pri: "1", proto: "https"),
      service("authorized", pri: "2", auth: "true"),
      service("second", pri: "20"),
      service("first", pri: "10"),
    ], type: NMOSServiceType.registration)
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver, registry: "first:8010") }
    XCTAssertEqual(Set(registry.calls.map(\.registry)), ["first:8010"])
  }

  func testAServerErrorMovesToTheNextRegistry() async throws {
    registry.override { call in call.registry == "first:8010" ? .init(status: 500) : nil }
    await describe()
    start(registryURL: nil)
    discovery.publish([service("first", pri: "10"), service("second", pri: "20")], type: NMOSServiceType.registration)
    await eventually("the receiver is registered with the second") {
      registry.holds("receiver", resources.receiver, registry: "second:8010")
    }
    XCTAssertEqual(registry.calls(to: "first:8010").count, 1)
    // the node was not registered anywhere, so there is nothing to ask the second about
    XCTAssertEqual(registrations("second:8010").first, "node")
    XCTAssertEqual(registry.calls(to: "second:8010").first?.path, "resource")
  }

  func testAFailedHeartbeatAsksTheNextRegistryWhetherItKnowsTheNode() async throws {
    await describe()
    start(registryURL: nil)
    discovery.publish([service("first", pri: "10"), service("second", pri: "20")], type: NMOSServiceType.registration)
    await eventually("the receiver is registered with the first") {
      registry.holds("receiver", resources.receiver, registry: "first:8010")
    }
    // the two share a registry, so the second already holds the node
    for (kind, id) in zip(["node", "device", "source", "flow", "sender", "receiver"], resources.all.map(\.id)) {
      registry.remember(kind, id, registry: "second:8010")
    }
    registry.override { call in
      if call.registry == "first:8010" { throw NMOSHTTPClientError.timedOut }
      return nil
    }
    await eventually("the second is heartbeated") { heartbeats("second:8010") >= 2 }
    XCTAssertEqual(registry.calls(to: "second:8010").first?.path, "health/nodes/\(resources.node)")
    XCTAssertEqual(registrations("second:8010"), [])
  }

  func testARegistryThatDoesNotKnowTheNodeAfterFailoverIsGivenEverything() async throws {
    await describe()
    start(registryURL: nil)
    discovery.publish([service("first", pri: "10"), service("second", pri: "20")], type: NMOSServiceType.registration)
    await eventually("the receiver is registered with the first") {
      registry.holds("receiver", resources.receiver, registry: "first:8010")
    }
    registry.override { call in call.registry == "first:8010" ? .init(status: 503) : nil }
    await eventually("the receiver is registered with the second") {
      registry.holds("receiver", resources.receiver, registry: "second:8010")
    }
    XCTAssertEqual(registry.calls(to: "second:8010").first?.path, "health/nodes/\(resources.node)")
    XCTAssertEqual(registrations("second:8010"), ["node", "device", "source", "flow", "sender", "receiver"])
  }

  func testBacksOffWhenNoRegistryAnswers() async throws {
    registry.override { _ in throw NMOSHTTPClientError.timedOut }
    await describe()
    start()
    // waits of 20, 40, 80, 80... ms: several attempts in half a second, but not a flood
    try await Task.sleep(for: .milliseconds(500))
    let attempts = registry.calls.count
    XCTAssertGreaterThanOrEqual(attempts, 4)
    XCTAssertLessThanOrEqual(attempts, 10)

    registry.override(nil)
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
  }

  func testUnregistersChildrenBeforeParentsOnShutdown() async throws {
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
    await stop()
    let removals = registry.calls.filter { $0.method == .DELETE }.map(\.path)
    XCTAssertEqual(removals, [
      "resource/receivers/\(resources.receiver)", "resource/senders/\(resources.sender)",
      "resource/flows/\(resources.flow)", "resource/sources/\(resources.source)",
      "resource/devices/\(resources.device)", "resource/nodes/\(resources.node)",
    ])
    XCTAssertFalse(registry.holds("node", resources.node))
  }

  func testStopsUnregisteringWhenTheRegistryDoesNotAnswer() async throws {
    await describe()
    start()
    await eventually("the receiver is registered") { registry.holds("receiver", resources.receiver) }
    registry.override { call in
      if call.method == .DELETE { throw NMOSHTTPClientError.timedOut }
      return nil
    }
    await stop()
    // one request went unanswered; the other five resources were not each waited for
    let removals = registry.calls.filter { $0.method == .DELETE }.map(\.path)
    XCTAssertEqual(removals, ["resource/receivers/\(resources.receiver)"])
  }
}

/// A client through which registering a resource takes a while, as it does of a busy
/// registry; heartbeats and removals are answered at once.
private struct SlowRegistrationClient: NMOSHTTPClient {
  let client: any NMOSHTTPClient
  let delay: Duration

  func send(_ method: HTTPMethod, _ url: URL, body: Data?) async throws -> NMOSHTTPClientResponse {
    if method == .POST, url.lastPathComponent == "resource" {
      try await Task.sleep(for: delay)
    }
    return try await client.send(method, url, body: body)
  }
}
