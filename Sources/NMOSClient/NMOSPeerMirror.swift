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

import Foundation
import Logging
import NMOS

/// Follows the nodes advertising themselves by DNS-SD, as `NMOSRegistryMirror` follows a
/// registry, for where there is none: what it delivers is the same, so a consumer can take
/// either. A node has no subscriptions, and IS-04 v1.3 says not to poll one, so it is read
/// when it is found and then only when its `ver_` TXT records say a collection has changed.
///
/// A record is only as good as the responder's word for it. If an update never reaches this
/// host, what is held of that collection stays as it was until the next one that does, and
/// nothing here can tell. A node advertising no `ver_` records says nothing of its changes at
/// all: IS-04 has a registered node withdraw them, though one that supports v1.2 or earlier
/// must go on advertising. It is read when found, and again only if it takes them up.
public actor NMOSPeerMirror {
  /// What's mirrored of what a node has `ver_` records for: its sources and flows are not.
  private static let kinds = [NMOSResourceKind.node, .device, .sender, .receiver]

  private struct Peer {
    var url: URL
    var txt: [String: String]
    /// What's held of the node, which is delivered once all of it has been read.
    var held = NMOSRegistrySnapshot()
    /// The `ver_` record each kind was last read under; those not read yet are absent.
    var read = [NMOSResourceKind: String]()
    var isComplete = false
    let wake: AsyncStream<Void>.Continuation
    let task: Task<Void, Never>

    /// A record that is absent is a value like any other: a node that drops or takes up its
    /// `ver_` records has started or stopped registering, and may have changed in the gap.
    func counter(_ kind: NMOSResourceKind) -> String { txt[kind.counterName, default: ""] }

    var isStale: Bool { NMOSPeerMirror.kinds.contains { read[$0] != counter($0) } }
  }

  private let discovery: any NMOSServiceDiscovery
  private let http: any NMOSHTTPClient
  private let retryBackoff: ClosedRange<Duration>
  private let logger: Logger
  /// Keyed by service instance, which is what stays the same if a node's address changes.
  private var peers = [String: Peer]()
  private var snapshot = NMOSRegistrySnapshot()
  private var continuation: AsyncStream<NMOSRegistrySnapshot>.Continuation?
  /// Counts the streams asked for, the last of which is the one being followed for.
  private var runs = 0

  /// `retryBackoff` is the wait before reading again a node that could not be read: the
  /// first wait, doubled each time up to the last.
  public init(
    discovery: any NMOSServiceDiscovery,
    http: any NMOSHTTPClient = NMOSFlyingFoxHTTPClient(),
    retryBackoff: ClosedRange<Duration> = .seconds(1)...(.seconds(30)),
    logger: Logger = Logger(label: "NMOSClient")
  ) {
    self.discovery = discovery
    self.http = http
    self.retryBackoff = retryBackoff
    self.logger = logger
  }

  /// The nodes as they stand, then again each time they change, latest first if they're not
  /// kept up with. It stops following when the stream is released, or ends if another is
  /// asked for.
  public nonisolated func snapshots() -> AsyncStream<NMOSRegistrySnapshot> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { await self.run(continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(_ continuation: AsyncStream<NMOSRegistrySnapshot>.Continuation) async {
    // the last stream may not have wound down, and this one takes over from it
    self.continuation?.finish()
    stop()
    self.continuation = continuation
    runs += 1
    let run = runs
    for await services in discovery.browse(type: NMOSServiceType.node) {
      guard run == runs else { break }
      found(services)
    }
    if run == runs { stop() }
    continuation.finish()
  }

  private func stop() {
    for peer in peers.values { peer.task.cancel() }
    peers.removeAll()
    snapshot = NMOSRegistrySnapshot()
  }

  /// The Node API a service advertises, if this client can use it: of this version, over
  /// plain HTTP, without authorization.
  static func apiURL(of service: NMOSDiscoveredService) -> URL? {
    let versions = service.txt["api_ver", default: ""].split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard versions.contains(NMOSNodeClient.apiVersion),
          service.txt["api_proto", default: "http"] == "http",
          service.txt["api_auth"] != "true" else { return nil }
    var host = service.host
    if host.hasSuffix(".") { host.removeLast() }
    if host.contains(":") { host = "[\(host)]" }
    return URL(string: "http://\(host):\(service.port)")
  }

  private func found(_ services: [NMOSDiscoveredService]) {
    var usable = [String: (service: NMOSDiscoveredService, url: URL)]()
    for service in services {
      if let url = Self.apiURL(of: service) { usable[service.name] = (service, url) }
    }
    for name in peers.keys where usable[name] == nil {
      peers.removeValue(forKey: name)?.task.cancel()
    }
    for (name, (service, url)) in usable {
      guard var peer = peers[name] else {
        start(name, at: url, txt: service.txt)
        continue
      }
      // the whole set comes round when any of it changes, which is no reason to try this
      // node again ahead of its backoff
      guard peer.url != url || peer.txt != service.txt else { continue }
      if peer.url != url { peer.read.removeAll() }
      peer.url = url
      peer.txt = service.txt
      peers[name] = peer
      peer.wake.yield()
    }
    publish()
  }

  private func start(_ name: String, at url: URL, txt: [String: String]) {
    let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task { await self.follow(name, wakes, wake) }
    peers[name] = Peer(url: url, txt: txt, wake: wake, task: task)
    wake.yield()
  }

  /// Each node has this to itself, so that one that doesn't answer keeps only itself waiting.
  private func follow(
    _ name: String,
    _ wakes: AsyncStream<Void>,
    _ wake: AsyncStream<Void>.Continuation
  ) async {
    var delay = retryBackoff.lowerBound
    var retry: Task<Void, Never>?
    defer { retry?.cancel() }
    for await _ in wakes {
      retry?.cancel()
      do {
        try await catchUp(name)
        delay = retryBackoff.lowerBound
      } catch {
        guard !Task.isCancelled else { return }
        logger.warning("cannot read NMOS node \(name): \(error)")
        retry = Task { [delay] in
          try? await Task.sleep(for: delay)
          if !Task.isCancelled { wake.yield() }
        }
        delay = min(delay * 2, retryBackoff.upperBound)
      }
    }
  }

  /// Reads what has changed, and goes on doing so for as long as more changes meanwhile. What
  /// was read before a failure is kept, and is not read again.
  private func catchUp(_ name: String) async throws {
    defer { publish() }
    while !Task.isCancelled, peers[name]?.isStale == true {
      try await read(name, at: \.nodes) { try await [$0.node()] }
      try await read(name, at: \.devices) { try await $0.resources() }
      try await read(name, at: \.senders) { try await $0.resources() }
      try await read(name, at: \.receivers) { try await $0.resources() }
    }
  }

  /// Reads a kind whose record has moved. Which way doesn't matter, since they wrap. What's
  /// read is taken to be as of the record seen before asking, never one that came later:
  /// if that changed meanwhile, this is stale already and will be read again.
  private func read<Resource: NMOSResourceRepresentable>(
    _ name: String,
    at keyPath: WritableKeyPath<NMOSRegistrySnapshot, [NMOSID: Resource]>,
    with fetch: @Sendable (NMOSNodeClient) async throws -> [Resource]
  ) async throws {
    let kind = Resource.kind
    guard let peer = peers[name], peer.read[kind] != peer.counter(kind) else { return }
    let resources = try await fetch(NMOSNodeClient(baseURL: peer.url, http: http))
    guard !Task.isCancelled, var current = peers[name], current.url == peer.url else { return }
    current.held[keyPath: keyPath] = Dictionary(resources.map { ($0.id, $0) }) { $1 }
    current.read[kind] = peer.counter(kind)
    current.isComplete = current.isComplete || current.read.count == Self.kinds.count
    peers[name] = current
  }

  private func publish() {
    var merged = NMOSRegistrySnapshot()
    // a node may be advertised more than once; instances are taken in order so that which
    // of them is held doesn't change from one snapshot to the next
    for (_, peer) in peers.sorted(by: { $0.key < $1.key }) where peer.isComplete {
      merged.nodes.merge(peer.held.nodes) { $1 }
      merged.devices.merge(peer.held.devices) { $1 }
      merged.senders.merge(peer.held.senders) { $1 }
      merged.receivers.merge(peer.held.receivers) { $1 }
    }
    guard merged != snapshot else { return }
    snapshot = merged
    continuation?.yield(merged)
  }
}
