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

/// A Registration API the node could register with.
struct NMOSRegistry: Sendable, Hashable {
  /// The root of its HTTP server, such as `http://registry:8010`.
  let url: URL
  /// Lower is preferred; 100 and above are registries under development.
  let priority: Int

  static let version = NMOSAPIVersion.v1_3

  init(url: URL, priority: Int = 0) {
    self.url = url
    self.priority = priority
  }

  /// A discovered service, if it offers this API version over plain HTTP without
  /// authorization, which is all the node can speak.
  init?(_ service: NMOSDiscoveredService) {
    let versions = (service.txt["api_ver"] ?? "").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard versions.contains(Self.version.description),
          (service.txt["api_proto"] ?? "http") == "http",
          (service.txt["api_auth"] ?? "false") != "true" else { return nil }
    var host = service.host
    if host.hasSuffix(".") { host.removeLast() }
    if host.contains(":") { host = "[\(host)]" }
    guard let url = URL(string: "http://\(host):\(service.port)") else { return nil }
    self.init(url: url, priority: service.txt["pri"].flatMap { Int($0) } ?? 100)
  }

  /// The registries to try, best first; those of equal priority in no fixed order.
  static func ordered(_ services: [NMOSDiscoveredService]) -> [NMOSRegistry] {
    var seen = Set<URL>()
    return services.compactMap(NMOSRegistry.init).shuffled()
      .sorted { $0.priority < $1.priority }
      .filter { seen.insert($0.url).inserted }
  }

  func url(_ path: String) -> URL {
    url.appendingPathComponent("\(NMOSRouter.root)/registration/\(Self.version)/\(path)")
  }
}

/// The IS-04 behaviour of a node towards the rest of the network: it registers its
/// resources with a Registration API and keeps them registered, or, where there is no
/// registry, advertises its Node API by DNS-SD with the `ver_` records peers observe.
actor NMOSNodeRegistration {
  /// The registry did not answer, or answered with a server error: use another.
  private struct RegistryFailure: Error, CustomStringConvertible {
    let description: String
  }

  private struct RegistrationRequest: Encodable {
    let type: String
    let data: NMOSResource
  }

  private typealias Versions = [NMOSResourceKind: [NMOSID: NMOSTimestamp]]

  private let configuration: NMOSNodeConfiguration
  private let store: NMOSResourceStore
  private let discovery: (any NMOSServiceDiscovery)?
  private let httpClient: (any NMOSHTTPClient)?
  private let logger: Logger
  private let clock = ContinuousClock()

  private var signal: AsyncStream<Void>.Continuation?
  private var timer: Task<Void, Never>?

  private var discovered = [NMOSRegistry]()
  /// While browsing has found nothing: when to stop waiting and operate peer-to-peer.
  /// Nil once browsing has reported, or where no registry is being looked for.
  private var discoveryDeadline: ContinuousClock.Instant?
  /// Registries that failed since the last time every one of them had.
  private var failed = Set<URL>()
  private var current: NMOSRegistry?
  /// Set on moving to another registry while registered: it may share the first's data.
  private var isAdopting = false
  /// The version of each resource the registry holds.
  private var registered = Versions()
  /// Versions the registry refused, which must not be offered again unchanged.
  private var rejected = Versions()
  private var lastHeartbeat: ContinuousClock.Instant?
  /// Heartbeats the registered node on schedule, whatever else is being said to the
  /// registry: registering many resources must not let the node be garbage collected.
  private var heartbeats: (registry: NMOSRegistry, node: NMOSID, task: Task<Void, Never>)?
  /// Counts the times the registry was found to hold nothing of this node, so that an
  /// answer to a request made before then is not taken to describe what it holds now.
  private var epoch = 0
  private var retryAt: ContinuousClock.Instant?
  private var backoff: Duration

  /// The `ver_` counters, one for each Node API collection.
  private var counters = [NMOSResourceKind: UInt8]()
  private var advertisement: (key: NMOSServiceAdvertisement, registration: any NMOSServiceRegistration)?

  init(
    configuration: NMOSNodeConfiguration,
    store: NMOSResourceStore,
    discovery: (any NMOSServiceDiscovery)?,
    httpClient: (any NMOSHTTPClient)?,
    logger: Logger
  ) {
    self.configuration = configuration
    self.store = store
    self.discovery = discovery
    self.httpClient = httpClient
    self.logger = logger
    backoff = configuration.registrationBackoff.lowerBound
  }

  /// Runs until the task is cancelled, then unregisters and withdraws the advertisement.
  func run() async {
    let (wake, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.signal = signal
    // subscribed before the first step, so that no change falls between the two
    let changes = await store.changes()
    let observing = Task { for await change in changes { self.note(change) } }
    var browsing: Task<Void, Never>?
    if let discovery, configuration.registryURL == nil, httpClient != nil {
      discoveryDeadline = clock.now + configuration.registryDiscoveryTimeout
      browsing = Task {
        for await services in discovery.browse(type: NMOSServiceType.registration) {
          self.found(services)
        }
      }
    }
    defer {
      observing.cancel()
      browsing?.cancel()
      timer?.cancel()
      heartbeats?.task.cancel()
    }

    signal.yield()
    for await _ in wake {
      await step()
      schedule()
    }
    // the task is cancelled, so the farewells are said from one that is not
    await Task.detached { await self.shutdown() }.value
  }

  // MARK: Events

  private func note(_ change: NMOSResourceChange) {
    counters[change.kind] = (counters[change.kind] ?? 0) &+ 1
    signal?.yield()
  }

  private func found(_ services: [NMOSDiscoveredService]) {
    discovered = NMOSRegistry.ordered(services)
    // browsing has spoken, so there is no longer anything to wait for
    discoveryDeadline = nil
    signal?.yield()
  }

  /// Wakes the loop when the next attempt to register is due, or when browsing for a
  /// registry has gone on long enough. Heartbeats keep their own time.
  private func schedule() {
    timer?.cancel()
    guard let deadline = [retryAt, discoveryDeadline].compactMap({ $0 }).min(), let signal else { return }
    timer = Task { [clock] in
      try? await clock.sleep(until: deadline)
      if !Task.isCancelled { signal.yield() }
    }
  }

  // MARK: Registered operation

  private var candidates: [NMOSRegistry] {
    guard httpClient != nil else { return [] }
    return configuration.registryURL.map { [NMOSRegistry(url: $0)] } ?? discovered
  }

  private func step() async {
    guard let node = await store.node else { return }
    if let retryAt, clock.now >= retryAt {
      self.retryAt = nil
      failed.removeAll()
    }
    if let discoveryDeadline, clock.now >= discoveryDeadline {
      self.discoveryDeadline = nil
    }
    while retryAt == nil {
      if current == nil {
        guard let next = candidates.first(where: { !failed.contains($0.url) }) else {
          if !candidates.isEmpty { backOff() }
          break
        }
        current = next
        isAdopting = !registered.isEmpty
        logger.info("NMOS: using the Registration API at \(next.url)")
      }
      guard let registry = current else { break }
      do {
        try await converse(with: registry, node: node)
        // unless a heartbeat found the registry failed while it was being talked to
        if current == registry { backoff = configuration.registrationBackoff.lowerBound }
        break
      } catch {
        // cancelled mid-request: the registry has not failed, and is still to be told goodbye
        if Task.isCancelled { break }
        abandon(registry, because: error)
      }
    }
    await advertise(node)
  }

  /// Gives up on a registry that did not answer, or answered with a server error.
  private func abandon(_ registry: NMOSRegistry, because error: any Error) {
    guard current == registry else { return }
    logger.warning("NMOS: the Registration API at \(registry.url) failed: \(error)")
    failed.insert(registry.url)
    current = nil
    stopHeartbeats()
  }

  /// Every known registry has failed: wait, longer each time, before trying them again.
  private func backOff() {
    retryAt = clock.now + backoff
    backoff = min(backoff * 2, configuration.registrationBackoff.upperBound)
  }

  private func converse(with registry: NMOSRegistry, node: NMOSNodeResource) async throws {
    if isAdopting {
      // a registry reached after another failed is asked first whether it knows the node
      isAdopting = false
      try await heartbeat(registry, node: node.id)
    }
    try await synchronise(registry, node: node)
  }

  /// Whether the registry is still the one in use and still holds the node, which a
  /// heartbeat made while a request was awaited may have found otherwise.
  private func holds(_ node: NMOSID, at registry: NMOSRegistry) -> Bool {
    current == registry && registered[.node]?[node] != nil
  }

  /// Brings the registry into line with the resource store: removals with children
  /// first, then additions and updates with parents first, as referential integrity needs.
  private func synchronise(_ registry: NMOSRegistry, node: NMOSNodeResource) async throws {
    if let previous = registered[.node]?.keys.first(where: { $0 != node.id }) {
      // another ID is another node; removing the old one takes its children with it
      try await delete(.node, id: previous, from: registry)
    }
    for kind in NMOSResourceKind.registrationOrder.reversed() where kind != .node {
      let present = await Set(store.resources(kind).map(\.id))
      for id in (registered[kind] ?? [:]).keys.filter({ !present.contains($0) }).sorted() {
        try await delete(kind, id: id, from: registry)
        guard holds(node.id, at: registry) else { return }
      }
    }
    for kind in NMOSResourceKind.registrationOrder {
      // nothing can be registered under a node the registry does not hold
      guard kind == .node || holds(node.id, at: registry) else { return }
      for resource in await store.resources(kind)
        where registered[kind]?[resource.id] != resource.version
        && rejected[kind]?[resource.id] != resource.version
      {
        try await post(resource, to: registry)
        // a heartbeat has meanwhile found the node gone: the loop is woken to start again
        guard holds(node.id, at: registry) else { return }
      }
    }
  }

  private func post(_ resource: NMOSResource, to registry: NMOSRegistry, isRetry: Bool = false) async throws {
    let kind = resource.kind
    let body = try NMOSJSONCoding.encoder.encode(RegistrationRequest(type: kind.rawValue, data: resource))
    let asked = epoch
    let response = try await send(.POST, registry.url("resource"), body: body)
    // the registry lost the node while this was asked, so the answer says nothing now
    guard epoch == asked, current == registry else { return }
    switch response.status {
    case 200 where kind == .node && registered[.node] == nil && !isRetry:
      // a record from before a restart, whose children may be stale: clear it and start again
      logger.info("NMOS: the registry already held this node; registering afresh")
      try await delete(.node, id: resource.id, from: registry)
      try await post(resource, to: registry, isRetry: true)
    case 200, 201:
      registered[kind, default: [:]][resource.id] = resource.version
      rejected[kind]?[resource.id] = nil
      if kind == .node {
        if lastHeartbeat == nil { lastHeartbeat = clock.now }
        startHeartbeats(with: registry, node: resource.id)
      }
    case 409 where !isRetry:
      // held at another API version, where it must be unregistered before it can be here
      try await unregister(at: response.headers["location"], from: registry)
      try await post(resource, to: registry, isRetry: true)
    case 400..<500:
      // the registry will not take this; offering it again unchanged could not succeed
      rejected[kind, default: [:]][resource.id] = resource.version
      logger.error("""
      NMOS: the registry refused \(kind.rawValue) \(resource.id) with \(response.status): \
      \(String(decoding: response.body, as: UTF8.self))
      """)
    default:
      throw RegistryFailure(description: "\(response.status) registering \(kind.rawValue) \(resource.id)")
    }
  }

  private func delete(_ kind: NMOSResourceKind, id: NMOSID, from registry: NMOSRegistry) async throws {
    let response = try await send(.DELETE, registry.url("resource/\(kind.rawValue)s/\(id)"))
    switch response.status {
    case 409:
      try await unregister(at: response.headers["location"], from: registry)
    case 200..<500:
      // gone, or never there, which comes to the same thing
      break
    default:
      throw RegistryFailure(description: "\(response.status) removing \(kind.rawValue) \(id)")
    }
    if kind == .node {
      forgetRegistration()
    } else {
      registered[kind]?[id] = nil
      rejected[kind]?[id] = nil
    }
  }

  /// Removes a resource through the API version the registry says it holds it at.
  private func unregister(at location: String?, from registry: NMOSRegistry) async throws {
    guard let location, let path = URL(string: location)?.path, !path.isEmpty,
          let url = URL(string: path, relativeTo: registry.url) else { return }
    let response = try await send(.DELETE, url)
    guard response.status < 500 else {
      throw RegistryFailure(description: "\(response.status) removing \(location)")
    }
  }

  private func heartbeat(_ registry: NMOSRegistry, node: NMOSID) async throws {
    let response = try await send(.POST, registry.url("health/nodes/\(node)"))
    switch response.status {
    case 200:
      lastHeartbeat = clock.now
      startHeartbeats(with: registry, node: node)
    case 404:
      // garbage collected, or never known to this registry: register everything again
      logger.info("NMOS: the registry no longer holds this node; registering again")
      forgetRegistration()
    case 409:
      try await unregister(at: response.headers["location"], from: registry)
      forgetRegistration()
    default:
      throw RegistryFailure(description: "\(response.status) on heartbeat")
    }
  }

  /// The registry holds nothing of this node any more, so there is nothing to heartbeat.
  private func forgetRegistration() {
    registered.removeAll()
    rejected.removeAll()
    lastHeartbeat = nil
    epoch += 1
    stopHeartbeats()
  }

  private func stopHeartbeats() {
    heartbeats?.task.cancel()
    heartbeats = nil
  }

  /// Heartbeats the node at the interval from now on, in a task of its own so that a
  /// heartbeat falls due on time however long the loop spends registering resources.
  private func startHeartbeats(with registry: NMOSRegistry, node: NMOSID) {
    if let heartbeats, heartbeats.registry == registry, heartbeats.node == node { return }
    stopHeartbeats()
    let task = Task { [clock] in
      while let due = self.heartbeatDue(at: registry, node: node) {
        try? await clock.sleep(until: due)
        guard !Task.isCancelled, await self.beat(registry, node: node) else { return }
      }
    }
    heartbeats = (registry, node, task)
  }

  private func heartbeatDue(at registry: NMOSRegistry, node: NMOSID) -> ContinuousClock.Instant? {
    guard holds(node, at: registry) else { return nil }
    return (lastHeartbeat ?? clock.now) + configuration.heartbeatInterval
  }

  /// One scheduled heartbeat. False once there is no more reason to send them here: the
  /// registry failed or no longer holds the node, and the loop is woken to deal with it.
  private func beat(_ registry: NMOSRegistry, node: NMOSID) async -> Bool {
    guard holds(node, at: registry) else { return false }
    do {
      try await heartbeat(registry, node: node)
    } catch {
      // stopped mid-request: the registry has not failed
      if Task.isCancelled { return false }
      abandon(registry, because: error)
    }
    if holds(node, at: registry) { return true }
    signal?.yield()
    return false
  }

  private func send(_ method: HTTPMethod, _ url: URL, body: Data? = nil) async throws -> NMOSHTTPClientResponse {
    guard let httpClient else { throw RegistryFailure(description: "no HTTP client") }
    return try await httpClient.send(method, url, body: body)
  }

  /// Controlled unregistration: children before the parents they refer to, then the node.
  private func shutdown() async {
    stopHeartbeats()
    if let registry = current {
      await unregisterEverything(from: registry)
      current = nil
    }
    await advertisement?.registration.withdraw()
    advertisement = nil
  }

  /// Stops at the first failure: a registry that does not answer one request will not
  /// answer the next, and each would be waited for in turn while the host shuts down.
  private func unregisterEverything(from registry: NMOSRegistry) async {
    for kind in NMOSResourceKind.registrationOrder.reversed() {
      for id in (registered[kind] ?? [:]).keys.sorted() {
        do {
          try await delete(kind, id: id, from: registry)
        } catch {
          // the registry will collect whatever is left once the heartbeats stop
          logger.info("NMOS: could not unregister \(kind.rawValue) \(id): \(error)")
          return
        }
      }
    }
  }

  // MARK: Peer-to-peer operation

  private static let counterNames: [(NMOSResourceKind, String)] = [
    (.node, "ver_slf"), (.source, "ver_src"), (.flow, "ver_flw"),
    (.device, "ver_dvc"), (.sender, "ver_snd"), (.receiver, "ver_rcv"),
  ]

  /// The service instance name: the node's label, so that a renamed device is found
  /// under its new name, cut to the 63 bytes of UTF-8 a DNS-SD label can hold without
  /// splitting a character. Nil for an empty label leaves the name to the responder.
  static func instanceName(_ label: String) -> String? {
    var name = label
    while name.utf8.count > 63 {
      name.removeLast()
    }
    return name.isEmpty ? nil : name
  }

  /// Advertises the Node API while there is no registry to use, and not otherwise: a
  /// registered node must withdraw its `ver_` records, and from v1.3 need not advertise.
  /// While browsing may still find a registry, it is too soon to say there is none.
  private func advertise(_ node: NMOSNodeResource) async {
    guard let discovery, configuration.peerToPeer, current == nil, candidates.isEmpty,
          discoveryDeadline == nil,
          let endpoint = node.api.endpoints.first, let port = UInt16(exactly: endpoint.port)
    else {
      await advertisement?.registration.withdraw()
      advertisement = nil
      return
    }
    var txt = [
      "api_proto": endpoint.protocol,
      "api_ver": node.api.versions.map(\.description).joined(separator: ","),
      "api_auth": endpoint.authorization == true ? "true" : "false",
    ]
    for (kind, name) in Self.counterNames {
      txt[name] = String(counters[kind] ?? 0)
    }
    let wanted = NMOSServiceAdvertisement(
      type: NMOSServiceType.node, name: Self.instanceName(node.label), port: port, txt: txt
    )
    guard wanted != advertisement?.key else { return }
    do {
      if let advertisement, advertisement.key.port == port, advertisement.key.name == wanted.name {
        try await advertisement.registration.update(txt: txt)
        self.advertisement = (wanted, advertisement.registration)
      } else {
        // a service cannot be renamed, so a new label is a new advertisement; the
        // counters are the node's, not the advertisement's, and carry over
        await advertisement?.registration.withdraw()
        advertisement = nil
        advertisement = try await (wanted, discovery.advertise(wanted))
      }
    } catch {
      logger.warning("NMOS: could not advertise the Node API: \(error)")
    }
  }
}
