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

/// DNS-SD as the test tells it: `deliver` is what a browse reports.
private final class FakeDiscovery: NMOSServiceDiscovery, Sendable {
  private struct Registration: NMOSServiceRegistration {
    func update(txt: [String: String]) async throws {}
    func withdraw() async {}
  }

  private struct State {
    var browsed = [String]()
    var latest: [NMOSDiscoveredService]?
    var browses = [AsyncStream<[NMOSDiscoveredService]>.Continuation]()
    var ended = 0
    var isOver = false
  }

  private let state = Mutex(State())

  var browsed: [String] { state.withLock { $0.browsed } }
  var ended: Int { state.withLock { $0.ended } }

  func advertise(_ advertisement: NMOSServiceAdvertisement) async throws -> any NMOSServiceRegistration {
    Registration()
  }

  func browse(type: String) -> AsyncStream<[NMOSDiscoveredService]> {
    let (services, continuation) = AsyncStream<[NMOSDiscoveredService]>.makeStream()
    continuation.onTermination = { [weak self] _ in
      self?.state.withLock { $0.ended += 1 }
    }
    let isOver = state.withLock {
      $0.browsed.append(type)
      $0.browses.append(continuation)
      if let latest = $0.latest { continuation.yield(latest) }
      return $0.isOver
    }
    if isOver { continuation.finish() }
    return services
  }

  func deliver(_ services: [NMOSDiscoveredService]) {
    state.withLock {
      $0.latest = services
      for browse in $0.browses {
        browse.yield(services)
      }
    }
  }

  /// Ends the browses there are, and any yet to start. Not under the lock: finishing calls
  /// `onTermination`, which takes it.
  func end() {
    let browses = state.withLock {
      $0.isOver = true
      return $0.browses
    }
    for browse in browses {
      browse.finish()
    }
  }
}

/// Node APIs as the test tells them, by URL. Each can be made to fail, or to wait: a request
/// held stays unanswered until it's let go, and is answered with what's served by then.
private final class FakeNodes: NMOSHTTPClient, Sendable {
  struct Unreachable: Error {}

  private struct State {
    /// What to answer each URL with: each answer uses one up, and the last of them stays.
    var bodies = [String: [String]]()
    var failing = Set<String>()
    var holding = Set<String>()
    var held = [String: [CheckedContinuation<Void, Never>]]()
    var requests = [(method: HTTPMethod, url: String)]()
  }

  private let state = Mutex(State())

  var requests: [(method: HTTPMethod, url: String)] { state.withLock { $0.requests } }

  func serve(_ url: String, _ bodies: String...) {
    state.withLock { $0.bodies[url] = bodies }
  }

  /// Serves a whole node at the root of `base`, with a device, and what's given under it.
  func serve(_ node: FakeNode, at base: String, senders: [String]? = nil, receivers: [String] = []) {
    let api = "\(base)/x-nmos/node/v1.3"
    serve("\(api)/self", node.selfJSON)
    serve("\(api)/devices", "[\(node.deviceJSON)]")
    serve("\(api)/senders", "[\((senders ?? [node.sender("out")]).joined(separator: ","))]")
    serve("\(api)/receivers", "[\(receivers.joined(separator: ","))]")
  }

  /// Failing is by prefix, so that a whole node can fail.
  func fail(_ prefix: String, _ failing: Bool = true) {
    state.withLock {
      if failing { $0.failing.insert(prefix) } else { $0.failing.remove(prefix) }
    }
  }

  func hold(_ url: String) {
    state.withLock { _ = $0.holding.insert(url) }
  }

  func release(_ url: String) {
    let waiting = state.withLock {
      $0.holding.remove(url)
      return $0.held.removeValue(forKey: url) ?? []
    }
    for continuation in waiting {
      continuation.resume()
    }
  }

  /// Lets go of the request made last of those held, leaving the others held.
  func releaseNewest(_ url: String) {
    let waiting = state.withLock { $0.held[url]?.popLast() }
    waiting?.resume()
  }

  func count(of url: String) -> Int {
    requests.filter { $0.url == url }.count
  }

  /// The URLs asked for, from the `after`th request on.
  func urls(after count: Int) -> [String] {
    requests.dropFirst(count).map(\.url)
  }

  func send(_ method: HTTPMethod, _ url: URL, body: Data?) async throws -> NMOSHTTPClientResponse {
    let key = url.absoluteString
    state.withLock { $0.requests.append((method, key)) }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let isHeld = state.withLock {
        guard $0.holding.contains(key) else { return false }
        $0.held[key, default: []].append(continuation)
        return true
      }
      if !isHeld { continuation.resume() }
    }
    return try state.withLock { state in
      if state.failing.contains(where: { key.hasPrefix($0) }) { throw Unreachable() }
      guard let body = state.bodies[key]?.first else { return NMOSHTTPClientResponse(status: 404) }
      if state.bodies[key]?.count ?? 0 > 1 { state.bodies[key]?.removeFirst() }
      return NMOSHTTPClientResponse(status: 200, body: Data(body.utf8))
    }
  }
}

/// A node's IDs and what it serves. The sender and receiver have what real nodes send.
private struct FakeNode {
  let id = UUID().uuidString.lowercased()
  let device = UUID().uuidString.lowercased()
  var label = "node"

  var selfJSON: String {
    """
    {"api":{"endpoints":[{"host":"192.0.2.1","port":80,"protocol":"http"}],"versions":["v1.3"]},
     "caps":{},"clocks":[{"name":"clk0","ref_type":"internal"}],"description":"","hostname":"node",
     "href":"http://192.0.2.1:80/","id":"\(id)","interfaces":[],"label":"\(label)","services":[],
     "tags":{},"version":"1793438317:873445749"}
    """
  }

  var deviceJSON: String {
    """
    {"controls":[],"description":"","id":"\(device)","label":"\(label)","node_id":"\(id)",
     "receivers":[],"senders":[],"tags":{},"type":"urn:x-nmos:device:generic",
     "version":"1793438317:739358425"}
    """
  }

  func sender(_ label: String, id: String = UUID().uuidString.lowercased()) -> String {
    """
    {"description":"","device_id":"\(device)","flow_id":"001974f9-aff3-5269-8eb2-c7ee609a1fe5",
     "id":"\(id)","interface_bindings":["en0"],"label":"\(label)","manifest_href":null,
     "subscription":{"active":true,"receiver_id":null},"tags":{},
     "transport":"urn:x-nmos:transport:rtp.mcast","version":"1793438317:739514827"}
    """
  }

  func receiver(_ label: String, id: String = UUID().uuidString.lowercased()) -> String {
    """
    {"caps":{"media_types":["audio/L32"]},"description":"","device_id":"\(device)",
     "format":"urn:x-nmos:format:audio","id":"\(id)","interface_bindings":["en0"],"label":"\(label)",
     "subscription":{"active":true,"sender_id":null},"tags":{},
     "transport":"urn:x-nmos:transport:rtp.mcast","version":"1793438317:980738878"}
    """
  }
}

/// A service as a peer advertises it, with all of its `ver_` records at `counter`.
private func service(
  _ name: String,
  host: String,
  port: UInt16 = 80,
  counter: Int? = 0,
  changing changes: [String: Int] = [:]
) -> NMOSDiscoveredService {
  var txt = ["api_proto": "http", "api_ver": "v1.3", "api_auth": "false"]
  if let counter {
    for kind in NMOSResourceKind.allCases {
      txt[kind.counterName] = String(changes[kind.counterName] ?? counter)
    }
  }
  return NMOSDiscoveredService(name: name, host: host, port: port, txt: txt)
}

/// Collects what a mirror delivers, so a test can look without ending the stream, which
/// would stop the mirror.
private final class Snapshots: Sendable {
  private final class Box: Sendable {
    let value = Mutex([NMOSRegistrySnapshot]())
  }

  private let box = Box()
  private let task: Task<Void, Never>

  init(_ mirror: NMOSPeerMirror) {
    let snapshots = mirror.snapshots()
    task = Task { [box] in
      for await snapshot in snapshots {
        box.value.withLock { $0.append(snapshot) }
      }
    }
  }

  deinit { task.cancel() }

  func stop() { task.cancel() }

  var all: [NMOSRegistrySnapshot] { box.value.withLock { $0 } }

  /// The first snapshot that satisfies `predicate`, however long a busy machine takes.
  func first(where predicate: @Sendable (NMOSRegistrySnapshot) -> Bool) async -> NMOSRegistrySnapshot? {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if let snapshot = all.first(where: predicate) { return snapshot }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
  }

  /// Waits for there to have been `count` snapshots, each marking the end of a pass over a
  /// node, by when anything else that was going to be read has been.
  func wait(for count: Int) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while all.count < count, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }
}

final class NMOSPeerMirrorTests: XCTestCase {
  private static let a = "http://192.0.2.1:80"
  private static let b = "http://192.0.2.2:80"
  private static let api = "x-nmos/node/v1.3"

  private let discovery = FakeDiscovery()
  private let nodes = FakeNodes()

  /// With a backoff that decides nothing: tests of it give their own.
  private func follow(retryBackoff: ClosedRange<Duration> = .milliseconds(1)...(.milliseconds(4))) -> Snapshots {
    Snapshots(NMOSPeerMirror(discovery: discovery, http: nodes, retryBackoff: retryBackoff))
  }

  private func senderLabels(_ snapshot: NMOSRegistrySnapshot?) -> [String] {
    (snapshot?.senders.values.map(\.label) ?? []).sorted()
  }

  private func waitForRequest(_ url: String, count: Int = 1) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while nodes.count(of: url) < count, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertGreaterThanOrEqual(nodes.count(of: url), count)
  }

  func testANodeAppearsAsARegistrysDoes() async throws {
    let node = FakeNode(label: "peer")
    nodes.serve(node, at: Self.a, receivers: [node.receiver("in")])
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()

    let snapshot = await snapshots.first { !$0.nodes.isEmpty }
    XCTAssertEqual(snapshot?.nodes.values.map(\.label), ["peer"])
    XCTAssertEqual(snapshot?.devices.count, 1)
    XCTAssertEqual(snapshot?.senders.count, 1)
    XCTAssertEqual(snapshot?.receivers.count, 1)
    XCTAssertEqual(discovery.browsed, [NMOSServiceType.node])
    XCTAssertEqual(nodes.requests.map(\.url).sorted(), [
      "\(Self.a)/\(Self.api)/devices", "\(Self.a)/\(Self.api)/receivers",
      "\(Self.a)/\(Self.api)/self", "\(Self.a)/\(Self.api)/senders",
    ])
    XCTAssertTrue(nodes.requests.allSatisfy { $0.method == .GET })
  }

  func testWhatCannotBeReadIsLeftOut() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a, senders: [node.sender("out"), #"{"id":"video"}"#])
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    let snapshot = await snapshots.first { !$0.nodes.isEmpty }
    XCTAssertEqual(senderLabels(snapshot), ["out"])
  }

  func testOnlyWhatsCounterChangedIsReadAgain() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    await snapshots.wait(for: 1)

    let (sender, receiver) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased())
    var counters = [String: Int]()
    for (step, kind) in [NMOSResourceKind.node, .device, .sender, .receiver].enumerated() {
      // everything has changed, and only what the record says so of should be seen to have
      var changed = node
      changed.label = "changed \(step)"
      nodes.serve(
        changed, at: Self.a,
        senders: [changed.sender(changed.label, id: sender)],
        receivers: [changed.receiver(changed.label, id: receiver)]
      )
      let before = nodes.requests.count
      counters[kind.counterName] = 1
      discovery.deliver([service("peer", host: "192.0.2.1", changing: counters)])
      await snapshots.wait(for: step + 2)
      XCTAssertEqual(snapshots.all.count, step + 2)
      XCTAssertEqual(nodes.urls(after: before), ["\(Self.a)/\(Self.api)/\(kind.collection)"])
    }

    let last = try XCTUnwrap(snapshots.all.last)
    XCTAssertEqual(last.nodes.values.map(\.label), ["changed 0"])
    XCTAssertEqual(last.devices.values.map(\.label), ["changed 1"])
    XCTAssertEqual(last.senders.values.map(\.label), ["changed 2"])
    XCTAssertEqual(last.receivers.values.map(\.label), ["changed 3"])
  }

  func testAChangedCollectionReplacesWhatWasHeldOfIt() async throws {
    let node = FakeNode()
    let (kept, dropped) = (node.sender("kept"), node.sender("dropped"))
    nodes.serve(node, at: Self.a, senders: [kept, dropped])
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    _ = await snapshots.first { $0.senders.count == 2 }

    nodes.serve(node, at: Self.a, senders: [kept, node.sender("added")])
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_snd": 1])])
    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "added" } }
    XCTAssertEqual(senderLabels(snapshot), ["added", "kept"])
  }

  func testChangesToWhatIsNotHeldAreNotRead() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    _ = await snapshots.first { !$0.nodes.isEmpty }

    let before = nodes.requests.count
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_src": 1, "ver_flw": 1])])
    // then something that is, which comes after
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_src": 1, "ver_flw": 1, "ver_snd": 1])])
    await waitForRequest("\(Self.a)/\(Self.api)/senders", count: 2)
    XCTAssertEqual(nodes.urls(after: before), ["\(Self.a)/\(Self.api)/senders"])
  }

  func testACounterThatWrapsHasStillChanged() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1", counter: 255)])
    let snapshots = follow()
    _ = await snapshots.first { !$0.nodes.isEmpty }

    nodes.serve(node, at: Self.a, senders: [node.sender("wrapped")])
    discovery.deliver([service("peer", host: "192.0.2.1", counter: 255, changing: ["ver_snd": 0])])
    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "wrapped" } }
    XCTAssertEqual(senderLabels(snapshot), ["wrapped"])
  }

  func testAnUnchangedSetReadsNothing() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    let other = FakeNode(label: "other")
    nodes.serve(other, at: Self.b)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    _ = await snapshots.first { !$0.nodes.isEmpty }

    let before = nodes.requests.count
    discovery.deliver([service("peer", host: "192.0.2.1")])
    discovery.deliver([service("peer", host: "192.0.2.1"), service("other", host: "192.0.2.2")])
    _ = await snapshots.first { $0.nodes.count == 2 }
    XCTAssertTrue(nodes.urls(after: before).allSatisfy { $0.hasPrefix(Self.b) })
  }

  func testAnUpdateMadeDuringAReadIsNotTakenToBeRead() async throws {
    let node = FakeNode()
    let senders = "\(Self.a)/\(Self.api)/senders"
    nodes.serve(node, at: Self.a)
    nodes.serve(senders, "[\(node.sender("old"))]", "[\(node.sender("new"))]")
    nodes.hold(senders)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    await waitForRequest(senders)

    // what the first read brings was read as of the record seen before asking, not this one
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_snd": 1])])
    try await Task.sleep(for: .milliseconds(20))
    nodes.release(senders)

    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "new" } }
    XCTAssertEqual(senderLabels(snapshot), ["new"])
    XCTAssertEqual(nodes.count(of: senders), 2)
  }

  func testANodeThatLeavesTheBrowseGoesFromTheSnapshot() async throws {
    let (leaving, staying) = (FakeNode(label: "leaving"), FakeNode(label: "staying"))
    nodes.serve(leaving, at: Self.a)
    nodes.serve(staying, at: Self.b)
    discovery.deliver([service("leaving", host: "192.0.2.1"), service("staying", host: "192.0.2.2")])
    let snapshots = follow()
    _ = await snapshots.first { $0.nodes.count == 2 }

    let before = snapshots.all.count
    discovery.deliver([service("staying", host: "192.0.2.2")])
    await snapshots.wait(for: before + 1)
    let snapshot = snapshots.all.last
    XCTAssertEqual(snapshot?.nodes.values.map(\.label), ["staying"])
    XCTAssertEqual(snapshot?.devices.count, 1)
    XCTAssertEqual(snapshot?.senders.count, 1)
  }

  func testAReadUnderwayWhenANodeLeavesDoesNotBringItBack() async throws {
    let (node, other) = (FakeNode(), FakeNode(label: "other"))
    let senders = "\(Self.a)/\(Self.api)/senders"
    nodes.serve(node, at: Self.a)
    nodes.serve(other, at: Self.b)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    await snapshots.wait(for: 1)

    nodes.hold(senders)
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_snd": 1])])
    await waitForRequest(senders, count: 2)
    discovery.deliver([])
    await snapshots.wait(for: 2)
    nodes.release(senders)

    discovery.deliver([service("other", host: "192.0.2.2")])
    await snapshots.wait(for: 3)
    XCTAssertEqual(snapshots.all.last?.nodes.values.map(\.label), ["other"])
    XCTAssertEqual(snapshots.all.last?.senders.count, 1)
  }

  func testAReadOfAnOldAddressIsNotTakenForTheNewOne() async throws {
    let node = FakeNode()
    let senders = "\(Self.a)/\(Self.api)/senders"
    nodes.serve(node, at: Self.a)
    nodes.serve(node, at: Self.b, senders: [node.sender("moved")])
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    await snapshots.wait(for: 1)

    nodes.hold(senders)
    nodes.serve(senders, "[\(node.sender("stale"))]")
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_snd": 1])])
    await waitForRequest(senders, count: 2)
    discovery.deliver([service("peer", host: "192.0.2.2", changing: ["ver_snd": 1])])
    try await Task.sleep(for: .milliseconds(20))
    nodes.release(senders)

    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "moved" } }
    XCTAssertEqual(senderLabels(snapshot), ["moved"])
    XCTAssertFalse(snapshots.all.contains { $0.senders.values.contains { $0.label == "stale" } })
  }

  func testAReadFromBeforeANodeLeftIsNotTakenForItsReturn() async throws {
    let (node, other) = (FakeNode(), FakeNode(label: "other"))
    let senders = "\(Self.a)/\(Self.api)/senders"
    nodes.serve(node, at: Self.a)
    nodes.serve(other, at: Self.b)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    await snapshots.wait(for: 1)

    nodes.hold(senders)
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_snd": 1])])
    await waitForRequest(senders, count: 2)
    discovery.deliver([])
    await snapshots.wait(for: 2)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    await waitForRequest(senders, count: 3)

    // the read made since it came back is answered first, and the one from before it last
    nodes.serve(senders, "[\(node.sender("fresh"))]", "[\(node.sender("late"))]")
    nodes.releaseNewest(senders)
    _ = await snapshots.first { $0.senders.values.contains { $0.label == "fresh" } }
    nodes.release(senders)
    try await Task.sleep(for: .milliseconds(20))

    discovery.deliver([service("peer", host: "192.0.2.1"), service("other", host: "192.0.2.2")])
    let snapshot = await snapshots.first { $0.nodes.count == 2 }
    XCTAssertEqual(senderLabels(snapshot), ["fresh", "out"])
  }

  func testAnUnreachableNodeKeepsOnlyItselfWaiting() async throws {
    let (silent, answering) = (FakeNode(), FakeNode(label: "answering"))
    nodes.serve(silent, at: Self.a)
    nodes.serve(answering, at: Self.b)
    // the first request of the first node is never answered, as a dead host's isn't for a while
    nodes.hold("\(Self.a)/\(Self.api)/self")
    discovery.deliver([service("silent", host: "192.0.2.1"), service("answering", host: "192.0.2.2")])
    let snapshots = follow()

    let snapshot = await snapshots.first { !$0.nodes.isEmpty }
    XCTAssertEqual(snapshot?.nodes.values.map(\.label), ["answering"])
    nodes.release("\(Self.a)/\(Self.api)/self")
    _ = await snapshots.first { $0.nodes.count == 2 }
  }

  func testANodeThatFailsLosesNoOther() async throws {
    let (failing, answering) = (FakeNode(), FakeNode(label: "answering"))
    nodes.serve(failing, at: Self.a)
    nodes.serve(answering, at: Self.b)
    discovery.deliver([service("failing", host: "192.0.2.1"), service("answering", host: "192.0.2.2")])
    let snapshots = follow()
    _ = await snapshots.first { $0.nodes.count == 2 }

    nodes.fail(Self.a)
    nodes.serve(answering, at: Self.b, senders: [answering.sender("new")])
    discovery.deliver([
      service("failing", host: "192.0.2.1", changing: ["ver_snd": 1]),
      service("answering", host: "192.0.2.2", changing: ["ver_snd": 1]),
    ])
    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "new" } }
    XCTAssertEqual(snapshot?.nodes.count, 2)
    XCTAssertEqual(snapshot?.senders.count, 2)
  }

  func testANodeThatCannotBeReadIsReadAgainAfterLongerAndLonger() async throws {
    let node = FakeNode()
    let url = "\(Self.a)/\(Self.api)/self"
    nodes.serve(node, at: Self.a)
    nodes.fail(Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let started = ContinuousClock.now
    let snapshots = follow(retryBackoff: .milliseconds(10)...(.milliseconds(40)))

    // waits of 10, 20, 40, 40... ms: four attempts take at least the first three waits
    await waitForRequest(url, count: 4)
    XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(70))
    XCTAssertEqual(snapshots.all.count, 0)

    nodes.fail(Self.a, false)
    _ = await snapshots.first { !$0.nodes.isEmpty }
    // read, and so not retried: only a change would have it read again
    let reads = nodes.requests.count
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(nodes.requests.count, reads)
  }

  func testAChangeDoesNotWaitForTheBackoff() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    nodes.fail(Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow(retryBackoff: .seconds(3600)...(.seconds(3600)))
    await waitForRequest("\(Self.a)/\(Self.api)/self")

    nodes.fail(Self.a, false)
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_slf": 1])])
    let snapshot = await snapshots.first { !$0.nodes.isEmpty }
    XCTAssertNotNil(snapshot)
  }

  func testAnotherNodesChangeIsNoReasonToRetryThisOne() async throws {
    let (failing, other) = (FakeNode(), FakeNode(label: "other"))
    nodes.serve(failing, at: Self.a)
    nodes.serve(other, at: Self.b)
    nodes.fail(Self.a)
    discovery.deliver([service("failing", host: "192.0.2.1")])
    let snapshots = follow(retryBackoff: .seconds(3600)...(.seconds(3600)))
    await waitForRequest("\(Self.a)/\(Self.api)/self")

    discovery.deliver([service("failing", host: "192.0.2.1"), service("other", host: "192.0.2.2")])
    _ = await snapshots.first { !$0.nodes.isEmpty }
    XCTAssertEqual(nodes.count(of: "\(Self.a)/\(Self.api)/self"), 1)
  }

  func testANodeKeepsWhatWasHeldWhileItCannotBeRead() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    _ = await snapshots.first { !$0.nodes.isEmpty }

    nodes.fail(Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1", changing: ["ver_snd": 1])])
    await waitForRequest("\(Self.a)/\(Self.api)/senders", count: 3)
    XCTAssertEqual(snapshots.all.count, 1)

    nodes.serve(node, at: Self.a, senders: [node.sender("new")])
    nodes.fail(Self.a, false)
    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "new" } }
    XCTAssertEqual(snapshot?.nodes.count, 1)
  }

  func testANodeIsNotDeliveredUntilAllOfItIsRead() async throws {
    let node = FakeNode()
    let receivers = "\(Self.a)/\(Self.api)/receivers"
    nodes.serve(node, at: Self.a)
    nodes.fail(receivers)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    await waitForRequest(receivers, count: 3)
    XCTAssertEqual(snapshots.all.count, 0)

    nodes.fail(receivers, false)
    let snapshot = await snapshots.first { !$0.nodes.isEmpty }
    XCTAssertEqual(snapshot?.senders.count, 1)
    // what was read before the failure wasn't read again
    XCTAssertEqual(nodes.count(of: "\(Self.a)/\(Self.api)/self"), 1)
    XCTAssertEqual(nodes.count(of: "\(Self.a)/\(Self.api)/senders"), 1)
  }

  func testAnErrorStatusIsAFailureToRead() async throws {
    // nothing is served at this node's URLs, so they answer 404
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    await waitForRequest("\(Self.a)/\(Self.api)/self", count: 2)
    XCTAssertEqual(snapshots.all.count, 0)
  }

  func testANodeWithNoCountersIsReadOnceAndAgainIfItTakesThemUp() async throws {
    // what a registered node advertises, as nmos-cpp's does here
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("registered", host: "192.0.2.1", counter: nil)])
    let snapshots = follow(retryBackoff: .seconds(3600)...(.seconds(3600)))
    _ = await snapshots.first { !$0.nodes.isEmpty }
    let before = nodes.requests.count
    XCTAssertEqual(before, 4)

    // it has lost its registry, and is operating peer-to-peer
    nodes.serve(node, at: Self.a, senders: [node.sender("new")])
    discovery.deliver([service("registered", host: "192.0.2.1")])
    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "new" } }
    XCTAssertNotNil(snapshot)
    XCTAssertEqual(nodes.requests.count, before + 4)
  }

  func testANewAddressIsReadAfreshAndTheNodeStaysMeanwhile() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    nodes.serve(node, at: Self.b, senders: [node.sender("moved")])
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let snapshots = follow()
    _ = await snapshots.first { !$0.nodes.isEmpty }

    discovery.deliver([service("peer", host: "192.0.2.2")])
    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "moved" } }
    XCTAssertEqual(senderLabels(snapshot), ["moved"])
    XCTAssertTrue(snapshots.all.allSatisfy { $0.nodes.count == 1 })
    XCTAssertEqual(nodes.count(of: "\(Self.b)/\(Self.api)/self"), 1)
  }

  func testANodeAdvertisedTwiceIsHeldOnceAndStaysUntilBothHaveGone() async throws {
    // IS-04 allows an advertisement for each port an API is exposed on
    let node = FakeNode()
    let other = "http://192.0.2.1:8080"
    nodes.serve(node, at: Self.a)
    nodes.serve(node, at: other)
    let (first, second) = (service("one", host: "192.0.2.1"), service("two", host: "192.0.2.1", port: 8080))
    discovery.deliver([first, second])
    let snapshots = follow()
    _ = await snapshots.first { $0.senders.count == 2 }

    discovery.deliver([second])
    nodes.serve(node, at: other, senders: [node.sender("still here")])
    discovery.deliver([service("two", host: "192.0.2.1", port: 8080, changing: ["ver_snd": 1])])
    let snapshot = await snapshots.first { $0.senders.values.contains { $0.label == "still here" } }
    XCTAssertEqual(senderLabels(snapshot), ["still here"])
    XCTAssertTrue(snapshots.all.allSatisfy { $0.nodes.count == 1 })

    discovery.deliver([])
    let gone = await snapshots.first(where: \.nodes.isEmpty)
    XCTAssertNotNil(gone)
  }

  func testServicesThatCannotBeUsedAreLeftAlone() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    var txt = service("https", host: "192.0.2.1").txt
    txt["api_proto"] = "https"
    let https = NMOSDiscoveredService(name: "https", host: "192.0.2.1", port: 80, txt: txt)
    nodes.serve(FakeNode(label: "usable"), at: Self.b)
    discovery.deliver([https, service("usable", host: "192.0.2.2")])
    let snapshots = follow()
    let snapshot = await snapshots.first { !$0.nodes.isEmpty }
    XCTAssertEqual(snapshot?.nodes.values.map(\.label), ["usable"])
    XCTAssertTrue(nodes.requests.allSatisfy { $0.url.hasPrefix(Self.b) })
  }

  func testAServiceNamesItsAPIIfItCanBeUsed() {
    func url(
      host: String = "node.local.",
      proto: String? = "http",
      ver: String? = "v1.0,v1.3",
      auth: String? = "false"
    ) -> String? {
      var txt = [String: String]()
      txt["api_proto"] = proto
      txt["api_ver"] = ver
      txt["api_auth"] = auth
      let service = NMOSDiscoveredService(name: "node", host: host, port: 8080, txt: txt)
      return NMOSPeerMirror.apiURL(of: service)?.absoluteString
    }
    XCTAssertEqual(url(), "http://node.local:8080")
    XCTAssertEqual(url(host: "fd00::1"), "http://[fd00::1]:8080")
    XCTAssertEqual(url(ver: "v1.2, v1.3"), "http://node.local:8080")
    // as with a registry, an absent `api_proto` is taken to be `http`
    XCTAssertNotNil(url(proto: nil))
    XCTAssertNotNil(url(auth: nil))
    XCTAssertNil(url(proto: "https"))
    XCTAssertNil(url(ver: "v1.2"))
    XCTAssertNil(url(ver: nil))
    XCTAssertNil(url(auth: "true"))
  }

  func testReleasingTheStreamStopsTheBrowseAndAStartAfterItIsAfresh() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let mirror = NMOSPeerMirror(discovery: discovery, http: nodes)

    for await snapshot in mirror.snapshots() where !snapshot.nodes.isEmpty {
      break
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while discovery.ended < 1, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertEqual(discovery.ended, 1)

    for await snapshot in mirror.snapshots() where !snapshot.nodes.isEmpty {
      break
    }
    XCTAssertEqual(nodes.count(of: "\(Self.a)/\(Self.api)/self"), 2)
  }

  func testAStreamStartedAsTheLastIsReleasedIsLeftToRun() async throws {
    // what the last one leaves behind as it winds down mustn't be taken for this one's
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let mirror = NMOSPeerMirror(discovery: discovery, http: nodes)
    for _ in 0..<500 {
      for await snapshot in mirror.snapshots() where !snapshot.nodes.isEmpty {
        break
      }
    }
  }

  func testAskingForAnotherStreamEndsTheFirst() async throws {
    let node = FakeNode()
    nodes.serve(node, at: Self.a)
    discovery.deliver([service("peer", host: "192.0.2.1")])
    let mirror = NMOSPeerMirror(discovery: discovery, http: nodes)
    var first = mirror.snapshots().makeAsyncIterator()
    let snapshot = await first.next()
    XCTAssertEqual(snapshot?.nodes.count, 1)

    var second = mirror.snapshots().makeAsyncIterator()
    let nothing = await first.next()
    XCTAssertNil(nothing)
    let next = await second.next()
    XCTAssertEqual(next?.nodes.count, 1)
  }

  func testTheStreamEndsWithTheBrowse() async throws {
    discovery.end()
    for await _ in NMOSPeerMirror(discovery: discovery, http: nodes).snapshots() {}
  }
}

/// The JSON of real Node APIs, cut down to a resource of each kind: brohavn and ark as
/// SwiftNMOS serves them, and nmos-cpp.
final class NMOSNodeClientTests: XCTestCase {
  private let base = URL(string: "http://node:8080")!

  private func client(_ responses: [String: String]) -> NMOSNodeClient {
    let nodes = FakeNodes()
    for (collection, body) in responses {
      nodes.serve("http://node:8080/x-nmos/node/v1.3/\(collection)", body)
    }
    return NMOSNodeClient(baseURL: base, http: nodes)
  }

  func testAFailureIsAFailure() async throws {
    do {
      _ = try await client([:]).node()
      XCTFail("nothing is served there")
    } catch let NMOSClientError.status(status, url) {
      XCTAssertEqual(status, 404)
      XCTAssertEqual(url, "http://node:8080/x-nmos/node/v1.3/self")
    }
  }

  func testTheSelfOfASwiftNMOSNode() async throws {
    let node = try await client(["self": #"""
    {"api":{"endpoints":[{"host":"10.10.32.8","port":80,"protocol":"http"}],"versions":["v1.3"]},"caps":{},"clocks":[{"gmid":"00-1d-c1-ff-fe-10-6c-16","locked":true,"name":"clk0","ref_type":"ptp","traceable":false,"version":"IEEE1588-2008"},{"name":"clk1","ref_type":"internal"}],"description":"Lukktone Router One","hostname":"brohavn","href":"http://10.10.32.8:80/","id":"8f7e0d84-ecb9-556e-abd5-f42a5d285f89","interfaces":[{"chassis_id":null,"name":"eno1","port_id":"c8-d3-ff-be-92-9a"},{"chassis_id":null,"name":"ens4","port_id":"8c-1f-64-e8-90-00"},{"chassis_id":null,"name":"enp8s0","port_id":"8c-1f-64-e8-90-01"}],"label":"brohavn","services":[],"tags":{},"version":"1793438317:873445749"}
    """#]).node()
    XCTAssertEqual(node.label, "brohavn")
    XCTAssertEqual(node.interfaces.count, 3)
    XCTAssertEqual(node.clocks.count, 2)
  }

  func testTheSelfOfAnNmosCppNode() async throws {
    let node = try await client(["self": #"""
    {"api":{"endpoints":[{"authorization":false,"host":"10.10.32.6","port":8010,"protocol":"http"},{"authorization":false,"host":"192.168.122.1","port":8010,"protocol":"http"},{"authorization":false,"host":"172.17.0.1","port":8010,"protocol":"http"}],"versions":["v1.0","v1.1","v1.2","v1.3"]},"caps":{},"clocks":[],"description":"","hostname":"nmos-registry.lukktone.com","href":"http://10.10.32.6:8010/","id":"fb09873f-655b-5988-97a9-0748d95a5027","interfaces":[{"chassis_id":"ee-a5-99-79-0b-bc","port_id":"ee-a5-99-79-0b-bc","name":"br0"},{"chassis_id":"ee-a5-99-79-0b-bc","port_id":"ee-d1-71-f8-74-df","name":"docker0"},{"chassis_id":"ee-a5-99-79-0b-bc","port_id":"52-54-00-00-47-4b","name":"virbr0"}],"label":"nmos-registry-registry","services":[{"href":"http://10.10.32.6:8010/x-dns-sd/v1.0","type":"urn:x-dns-sd/v1.0"},{"href":"http://10.10.32.6:8010/x-dns-sd/v1.1","type":"urn:x-dns-sd/v1.1"}],"tags":{},"version":"1790819522:850635529"}
    """#]).node()
    XCTAssertEqual(node.label, "nmos-registry-registry")
    XCTAssertEqual(node.api.endpoints.count, 3)
    XCTAssertEqual(node.services.count, 2)
  }

  func testTheCollectionsOfASwiftNMOSNode() async throws {
    let client = client([
      "devices": #"""
      [{"controls":[{"href":"http://10.10.32.8:80/x-nmos/connection/v1.2/","type":"urn:x-nmos:control:sr-ctrl/v1.2"},{"href":"http://10.10.32.8:80/x-nmos/connection/v1.1/","type":"urn:x-nmos:control:sr-ctrl/v1.1"},{"href":"ws://10.10.32.8:80/x-nmos/ncp/v1.0","type":"urn:x-nmos:control:ncp/v1.0"}],"description":"Lukktone Router One","id":"0b1c2917-c3e5-5030-82d6-96191cd571af","label":"brohavn","node_id":"8f7e0d84-ecb9-556e-abd5-f42a5d285f89","receivers":[],"senders":[],"tags":{},"type":"urn:x-nmos:device:generic","version":"1793438317:739358425"}]
      """#,
      "senders": #"""
      [{"description":"MediaTransportApplication output 1006","device_id":"0b1c2917-c3e5-5030-82d6-96191cd571af","flow_id":"001974f9-aff3-5269-8eb2-c7ee609a1fe5","id":"02b1619b-a6e0-5dc3-8c01-9ea3aeb929bf","interface_bindings":["ens4"],"label":"AES67 out 6","manifest_href":"http://10.10.32.8:80/x-nmos/connection/v1.1/single/senders/02b1619b-a6e0-5dc3-8c01-9ea3aeb929bf/transportfile","subscription":{"active":true,"receiver_id":null},"tags":{},"transport":"urn:x-nmos:transport:rtp.mcast","version":"1793438317:739514827"},
       {"description":"RouterOne output 1016","device_id":"002563da-2743-5213-af1e-3f2e096f0a9b","flow_id":"0613c66c-d55c-57e2-82df-f77bdcc81c05","id":"03f74782-5a60-5fef-8525-e24f602e58cf","interface_bindings":["enP1p1s0"],"label":"AVB out 16","manifest_href":null,"subscription":{"active":true,"receiver_id":null},"tags":{},"transport":"urn:x-nmos:transport:milan","version":"1793440183:746914625"}]
      """#,
      "receivers": #"""
      [{"caps":{"media_types":["audio/L32"]},"description":"brohavn input 7","device_id":"0b1c2917-c3e5-5030-82d6-96191cd571af","format":"urn:x-nmos:format:audio","id":"05637b07-6e6e-571c-9c2e-a27d014edfc8","interface_bindings":["enp8s0"],"label":"AVB in 7","subscription":{"active":true,"sender_id":null},"tags":{},"transport":"urn:x-nmos:transport:milan","version":"1793438317:980738878"}]
      """#,
    ])
    let devices = try await client.resources(NMOSDeviceResource.self)
    let senders = try await client.resources(NMOSSenderResource.self)
    let receivers = try await client.resources(NMOSReceiverResource.self)
    XCTAssertEqual(devices.first?.controls.count, 3)
    XCTAssertEqual(senders.count, 2)
    XCTAssertEqual(receivers.first?.label, "AVB in 7")
  }

  func testACollectionThatIsNotOneIsAFailure() async throws {
    do {
      _ = try await client(["senders": "{}"]).resources(NMOSSenderResource.self)
      XCTFail("that's no list of senders")
    } catch is DecodingError {}
  }
}
