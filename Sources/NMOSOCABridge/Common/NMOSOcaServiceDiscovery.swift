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
import NMOS
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

#if canImport(dnssd)

/// DNS-SD for the node through SwiftOCA's dns_sd wrapper, so it talks to whichever
/// responder the host runs (mDNSResponder, or Avahi through its dns_sd library).
public struct NMOSOcaServiceDiscovery: NMOSServiceDiscovery {
  private struct Registration: NMOSServiceRegistration {
    let registration: DNSServiceRegistration

    func update(txt: [String: String]) async throws {
      try await registration.update(txtRecord: NMOSOcaServiceDiscovery.entries(txt))
    }

    func withdraw() async {
      await registration.deregister()
    }
  }

  /// The host's search domains, less `local`, to browse by unicast DNS beside the
  /// default ones. Asked for again from time to time, since a DHCP lease can come or
  /// change after the node starts; none by default, which leaves only mDNS.
  private let searchDomains: @Sendable () async -> [String]

  public init(searchDomains: @escaping @Sendable () async -> [String] = { [] }) {
    self.searchDomains = searchDomains
  }

  /// The service stays advertised until it is withdrawn, not until the registration is
  /// released. Throws `DNSServiceError`, as it does when no responder is running.
  public func advertise(_ advertisement: NMOSServiceAdvertisement) async throws -> any NMOSServiceRegistration {
    try await Registration(registration: DNSServiceRegistration(
      name: advertisement.name,
      regType: advertisement.type,
      port: advertisement.port,
      txtRecord: Self.entries(advertisement.txt)
    ))
  }

  /// Nothing is delivered until a service is found: mDNS cannot say there are none.
  /// Browsing restarts by itself if the responder is not running or is restarted.
  ///
  /// The default domains are browsed, and each of the host's search domains by unicast
  /// DNS; what the search domains hold is reported in preference to what mDNS finds.
  public func browse(type: String) -> AsyncStream<[NMOSDiscoveredService]> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let found = NMOSOcaDiscoveredServices(continuation: continuation)
      let searchDomains = searchDomains
      let task = Task {
        await withTaskGroup(of: Void.self) { group in
          group.addTask { await Self.observe(type: type, domain: nil, into: found) }
          group.addTask { await Self.observeSearchDomains(searchDomains, type: type, into: found) }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static let browseRetryInterval = Duration.seconds(5)
  private static let resolveTimeout = Duration.seconds(5)
  private static let searchDomainInterval = Duration.seconds(30)

  /// Browses each search domain for as long as it is one, and no longer.
  private static func observeSearchDomains(
    _ searchDomains: @Sendable () async -> [String],
    type: String,
    into found: NMOSOcaDiscoveredServices
  ) async {
    var observing = [String: Task<Void, Never>]()
    while !Task.isCancelled {
      let domains = await Set(searchDomains())
      for domain in domains where observing[domain] == nil {
        observing[domain] = Task { await observe(type: type, domain: domain, into: found) }
      }
      for domain in observing.keys where !domains.contains(domain) {
        observing.removeValue(forKey: domain)?.cancel()
        await found.found([], in: domain)
      }
      try? await Task.sleep(for: searchDomainInterval)
    }
    for task in observing.values { task.cancel() }
  }

  /// Browses one domain, nil being the default ones, and passes on what it holds.
  private static func observe(type: String, domain: String?, into found: NMOSOcaDiscoveredServices) async {
    let (resolved, continuation) = AsyncStream<[NMOSDiscoveredService]>
      .makeStream(bufferingPolicy: .bufferingNewest(1))
    let browser = NMOSOcaServiceBrowser(continuation: continuation) { await Self.resolve($0) }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await browse(type: type, domain: domain, into: browser, continuation) }
      group.addTask {
        for await services in resolved { await found.found(services, in: domain) }
      }
    }
  }

  private static func browse(
    type: String,
    domain: String?,
    into browser: NMOSOcaServiceBrowser,
    _ continuation: AsyncStream<[NMOSDiscoveredService]>.Continuation
  ) async {
    while !Task.isCancelled {
      if let results = try? DNSServiceDiscovery.browse(regType: type, domain: domain) {
        for await result in results {
          await browser.handle(NMOSOcaBrowseEvent(
            isAdded: result.isAdded, name: result.name, regType: result.regType,
            domain: result.domain, interfaceIndex: result.interfaceIndex
          ))
        }
      }
      // no responder, or the connection to it failed: what was found is no longer known
      await browser.reset()
      try? await Task.sleep(for: browseRetryInterval)
    }
    await browser.reset()
    continuation.finish()
  }

  /// Where the instance can be reached, nil if it does not resolve in time.
  private static func resolve(_ event: NMOSOcaBrowseEvent) async -> NMOSDiscoveredService? {
    guard let resolution = await resolution(of: event), !Task.isCancelled else { return nil }
    // a numeric address spares the consumer resolving a `.local` name itself
    let addresses = await DNSServiceDiscovery.addresses(
      of: resolution.hostname,
      interfaceIndex: resolution.interfaceIndex
    )
    let hostname = resolution.hostname
    return NMOSDiscoveredService(
      name: event.name,
      host: addresses.first ?? (hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname),
      port: resolution.port,
      txt: resolution.txtRecords
    )
  }

  /// The first answer to resolving the instance, nil if none comes in time.
  private static func resolution(of event: NMOSOcaBrowseEvent) async -> DNSServiceResolution? {
    let resolutions = DNSServiceDiscovery.resolve(
      name: event.name,
      regType: event.regType,
      domain: event.domain
    )
    return await withTaskGroup(of: DNSServiceResolution?.self) { group in
      group.addTask {
        for await resolution in resolutions { return resolution }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: resolveTimeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  /// A TXT record's entries in a fixed order, so the same dictionary is the same record.
  private static func entries(_ txt: [String: String]) -> [(String, String)] {
    txt.sorted { $0.key < $1.key }
  }
}

#else

/// Without a dns_sd library the node advertises nothing and finds nothing, which leaves
/// it reachable only by a configured registry.
public struct NMOSOcaServiceDiscovery: NMOSServiceDiscovery {
  private struct Registration: NMOSServiceRegistration {
    func update(txt: [String: String]) async throws {}
    func withdraw() async {}
  }

  public init(searchDomains: @escaping @Sendable () async -> [String] = { [] }) {}

  public func advertise(_ advertisement: NMOSServiceAdvertisement) async throws -> any NMOSServiceRegistration {
    Registration()
  }

  public func browse(type: String) -> AsyncStream<[NMOSDiscoveredService]> {
    AsyncStream { continuation in
      continuation.finish()
    }
  }
}

#endif

/// A service instance a browse found, or had found and has now lost.
struct NMOSOcaBrowseEvent: Sendable, Hashable {
  /// False when the service has gone away.
  let isAdded: Bool
  let name: String
  let regType: String
  let domain: String
  let interfaceIndex: UInt32
}

/// Observes one browse: resolves each instance it finds and reports the resolved set.
/// It is told what the browse finds and how to resolve it, and knows nothing of dns_sd.
actor NMOSOcaServiceBrowser {
  typealias Resolver = @Sendable (NMOSOcaBrowseEvent) async -> NMOSDiscoveredService?

  private struct Instance: Hashable {
    let name: String
    let domain: String
  }

  private let continuation: AsyncStream<[NMOSDiscoveredService]>.Continuation
  private let resolver: Resolver
  /// The wait before resolving again an instance that did not resolve: the first wait,
  /// doubled each time up to the last.
  private let resolveBackoff: ClosedRange<Duration>
  /// The interfaces each instance has been seen on; it is gone when it has left them all.
  private var interfaces = [Instance: Set<UInt32>]()
  private var resolved = [Instance: NMOSDiscoveredService]()
  private var resolving = [Instance: Task<Void, Never>]()

  init(
    continuation: AsyncStream<[NMOSDiscoveredService]>.Continuation,
    resolveBackoff: ClosedRange<Duration> = .seconds(1)...(.seconds(60)),
    resolver: @escaping Resolver
  ) {
    self.continuation = continuation
    self.resolveBackoff = resolveBackoff
    self.resolver = resolver
  }

  func handle(_ event: NMOSOcaBrowseEvent) {
    let instance = Instance(name: event.name, domain: event.domain)
    if event.isAdded {
      let isNew = interfaces[instance] == nil
      interfaces[instance, default: []].insert(event.interfaceIndex)
      guard isNew else { return }
      resolving[instance] = Task { await self.resolve(instance, as: event) }
    } else {
      interfaces[instance]?.remove(event.interfaceIndex)
      guard interfaces[instance]?.isEmpty == true else { return }
      interfaces[instance] = nil
      resolving.removeValue(forKey: instance)?.cancel()
      if resolved.removeValue(forKey: instance) != nil { report() }
    }
  }

  /// Resolves the instance, again and less often for as long as it is advertised and
  /// does not resolve: a browse reports an instance once, so nothing else would retry.
  private func resolve(_ instance: Instance, as event: NMOSOcaBrowseEvent) async {
    var wait = resolveBackoff.lowerBound
    while !Task.isCancelled, interfaces[instance] != nil {
      if let service = await resolver(event) {
        guard !Task.isCancelled, interfaces[instance] != nil else { return }
        resolved[instance] = service
        resolving[instance] = nil
        report()
        return
      }
      try? await Task.sleep(for: wait)
      wait = min(wait * 2, resolveBackoff.upperBound)
    }
  }

  /// Forgets everything found, as when the browse it came from has ended.
  func reset() {
    for task in resolving.values { task.cancel() }
    resolving.removeAll()
    interfaces.removeAll()
    if !resolved.isEmpty {
      resolved.removeAll()
      report()
    }
  }

  private func report() {
    continuation.yield(resolved.values.sorted { $0.name < $1.name })
  }
}
