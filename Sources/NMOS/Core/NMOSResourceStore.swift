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

/// A change to the resource store, as IS-04 registration and the `ver_` records observe it.
public struct NMOSResourceChange: Sendable, Hashable {
  public enum Change: Sendable, Hashable {
    case added, modified, removed
  }

  public let kind: NMOSResourceKind
  public let id: NMOSID
  public let change: Change

  public init(kind: NMOSResourceKind, id: NMOSID, change: Change) {
    self.kind = kind
    self.id = id
    self.change = change
  }
}

/// The node's IS-04 resources. Whatever describes the device writes them here; the Node
/// API, registration and the Connection API read them and observe `changes()`.
public actor NMOSResourceStore {
  private var resources = [NMOSResourceKind: [NMOSID: NMOSResource]]()
  private var latestVersion = NMOSTimestamp(seconds: 0)
  private var observers = [UInt64: AsyncStream<NMOSResourceChange>.Continuation]()
  private var nextObserverID: UInt64 = 0
  private let now: @Sendable () -> NMOSTimestamp
  private var subscriptionsAreManaged = false

  public init(now: @escaping @Sendable () -> NMOSTimestamp = { .now() }) {
    self.now = now
  }

  // MARK: Reading

  public func resource(_ kind: NMOSResourceKind, id: NMOSID) -> NMOSResource? {
    resources[kind]?[id]
  }

  /// The resources of a kind, ordered by ID so that listings are stable.
  public func resources(_ kind: NMOSResourceKind) -> [NMOSResource] {
    (resources[kind] ?? [:]).values.sorted { $0.id < $1.id }
  }

  public var node: NMOSNodeResource? {
    guard case let .node(node) = resources[.node]?.values.first else { return nil }
    return node
  }

  public var devices: [NMOSDeviceResource] {
    resources(.device).compactMap { if case let .device(resource) = $0 { resource } else { nil } }
  }

  public var sources: [NMOSSourceResource] {
    resources(.source).compactMap { if case let .source(resource) = $0 { resource } else { nil } }
  }

  public var flows: [NMOSFlowResource] {
    resources(.flow).compactMap { if case let .flow(resource) = $0 { resource } else { nil } }
  }

  public var senders: [NMOSSenderResource] {
    resources(.sender).compactMap { if case let .sender(resource) = $0 { resource } else { nil } }
  }

  public var receivers: [NMOSReceiverResource] {
    resources(.receiver).compactMap { if case let .receiver(resource) = $0 { resource } else { nil } }
  }

  // MARK: Writing

  /// Adds the resource, or replaces the one with its ID. The `version` passed in is
  /// ignored: the stored version changes only if the content did. Returns that version.
  @discardableResult
  public func upsert(_ resource: NMOSResource) -> NMOSTimestamp {
    var resource = resource
    let existing = resources[resource.kind]?[resource.id]
    if let existing {
      if subscriptionsAreManaged { resource.keepSubscription(of: existing) }
      resource.version = existing.version
      guard resource != existing else { return existing.version }
    }
    resource.version = nextVersion()
    resources[resource.kind, default: [:]][resource.id] = resource
    notify(.init(kind: resource.kind, id: resource.id, change: existing == nil ? .added : .modified))
    return resource.version
  }

  /// Makes the store hold exactly `resources` for the given kinds: upserts each one and
  /// removes any other resource of those kinds.
  public func reconcile(_ resources: [NMOSResource], replacing kinds: Set<NMOSResourceKind>) {
    // children go before the parents they refer to, as controlled unregistration requires
    for kind in NMOSResourceKind.registrationOrder.reversed() where kinds.contains(kind) {
      let kept = Set(resources.filter { $0.kind == kind }.map(\.id))
      for id in (self.resources[kind] ?? [:]).keys.filter({ !kept.contains($0) }).sorted() {
        remove(kind, id: id)
      }
    }
    for kind in NMOSResourceKind.registrationOrder {
      for resource in resources where resource.kind == kind {
        upsert(resource)
      }
    }
  }

  @discardableResult
  public func remove(_ kind: NMOSResourceKind, id: NMOSID) -> Bool {
    guard resources[kind]?.removeValue(forKey: id) != nil else { return false }
    notify(.init(kind: kind, id: id, change: .removed))
    return true
  }

  // MARK: Subscriptions

  /// Makes `setSubscription` the only way a sender's or receiver's `subscription` changes
  /// once the resource exists: an upsert then keeps the one the resource has. The
  /// Connection API asks for this, so that whatever describes the device cannot write
  /// over the connection it recorded with a description read before it was made.
  public func manageSubscriptions() {
    subscriptionsAreManaged = true
  }

  /// Sets a sender's or receiver's `subscription` in one step. `peer` is the resource at
  /// the other end, which IS-04 names only while the connection is active. `touch` gives
  /// the resource a new version even if nothing changed. Returns the resulting version.
  @discardableResult
  public func setSubscription(
    _ kind: NMOSResourceKind,
    id: NMOSID,
    active: Bool,
    peer: NMOSID?,
    touch: Bool = false
  ) -> NMOSTimestamp? {
    guard let existing = resources[kind]?[id] else { return nil }
    var resource = existing
    switch resource {
    case var .sender(sender):
      sender.subscription = .init(receiverID: active ? peer : nil, active: active)
      resource = .sender(sender)
    case var .receiver(receiver):
      receiver.subscription = .init(senderID: active ? peer : nil, active: active)
      resource = .receiver(receiver)
    default:
      return nil
    }
    guard resource != existing || touch else { return existing.version }
    resource.version = nextVersion()
    resources[kind]?[id] = resource
    notify(.init(kind: kind, id: id, change: .modified))
    return resource.version
  }

  /// Gives the resource a new version without changing it, which IS-05 requires when a
  /// connection is re-activated with the same parameters.
  @discardableResult
  public func touch(_ kind: NMOSResourceKind, id: NMOSID) -> NMOSTimestamp? {
    guard var resource = resources[kind]?[id] else { return nil }
    resource.version = nextVersion()
    resources[kind]?[id] = resource
    notify(.init(kind: kind, id: id, change: .modified))
    return resource.version
  }

  // MARK: Observing

  /// Every change from now on. Each call returns its own stream, which ends when the
  /// caller stops iterating it.
  public func changes() -> AsyncStream<NMOSResourceChange> {
    let id = nextObserverID
    nextObserverID += 1
    let (stream, continuation) = AsyncStream<NMOSResourceChange>.makeStream()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    return stream
  }

  private func removeObserver(_ id: UInt64) {
    observers[id] = nil
  }

  private func notify(_ change: NMOSResourceChange) {
    for observer in observers.values {
      observer.yield(change)
    }
  }

  // versions must increase even when the clock does not
  private func nextVersion() -> NMOSTimestamp {
    latestVersion = max(now(), latestVersion.next)
    return latestVersion
  }
}

private extension NMOSResource {
  /// Takes the `subscription` of `other`, where both are senders or both receivers.
  mutating func keepSubscription(of other: NMOSResource) {
    switch (self, other) {
    case (var .sender(sender), let .sender(existing)):
      sender.subscription = existing.subscription
      self = .sender(sender)
    case (var .receiver(receiver), let .receiver(existing)):
      receiver.subscription = existing.subscription
      self = .receiver(receiver)
    default:
      break
    }
  }
}
