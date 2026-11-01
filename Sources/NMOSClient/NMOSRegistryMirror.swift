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

/// What a registry holds of what a controller routes, or what `NMOSPeerMirror` puts together
/// to the same effect where there is no registry.
public struct NMOSRegistrySnapshot: Sendable, Hashable {
  public var nodes = [NMOSID: NMOSNodeResource]()
  public var devices = [NMOSID: NMOSDeviceResource]()
  public var senders = [NMOSID: NMOSSenderResource]()
  public var receivers = [NMOSID: NMOSReceiverResource]()

  public init() {}
}

/// Follows a registry, keeping a copy of it. Changes arrive by subscription, so this is told of
/// them as they happen, and a subscription that fails is made again.
public actor NMOSRegistryMirror {
  private static let initialRetryDelay = Duration.seconds(1)
  private static let maximumRetryDelay = Duration.seconds(30)

  private let client: NMOSQueryClient
  private let logger: Logger
  private var snapshot = NMOSRegistrySnapshot()
  private var continuation: AsyncStream<NMOSRegistrySnapshot>.Continuation?

  public init(client: NMOSQueryClient, logger: Logger = Logger(label: "NMOSClient")) {
    self.client = client
    self.logger = logger
  }

  /// The registry as it stands, then again each time it changes, latest first if it's not
  /// kept up with. It stops following when the stream is released.
  public nonisolated func snapshots() -> AsyncStream<NMOSRegistrySnapshot> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { await self.run(continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(_ continuation: AsyncStream<NMOSRegistrySnapshot>.Continuation) async {
    self.continuation = continuation
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.follow(NMOSNodeResource.self, at: \.nodes) }
      group.addTask { await self.follow(NMOSDeviceResource.self, at: \.devices) }
      group.addTask { await self.follow(NMOSSenderResource.self, at: \.senders) }
      group.addTask { await self.follow(NMOSReceiverResource.self, at: \.receivers) }
    }
    continuation.finish()
  }

  private func follow<Resource: NMOSResourceRepresentable>(
    _ type: Resource.Type,
    at keyPath: WritableKeyPath<NMOSRegistrySnapshot, [NMOSID: Resource]>
  ) async {
    var delay = Self.initialRetryDelay
    while !Task.isCancelled {
      do {
        var isFirst = true
        for try await changes in try await client.changes(Resource.self) {
          delay = Self.initialRetryDelay
          apply(changes, at: keyPath, replacing: isFirst)
          isFirst = false
        }
      } catch {
        logger.warning("lost NMOS \(Resource.kind.rawValue)s: \(error)")
      }
      try? await Task.sleep(for: delay)
      delay = min(delay * 2, Self.maximumRetryDelay)
    }
  }

  private func apply<Resource: NMOSResourceRepresentable>(
    _ changes: [NMOSResourceChange<Resource>],
    at keyPath: WritableKeyPath<NMOSRegistrySnapshot, [NMOSID: Resource]>,
    replacing: Bool
  ) {
    let before = snapshot
    if replacing { snapshot[keyPath: keyPath] = [:] }
    for change in changes {
      switch change {
      case let .updated(resource): snapshot[keyPath: keyPath][resource.id] = resource
      case let .removed(id): snapshot[keyPath: keyPath][id] = nil
      }
    }
    if snapshot != before { continuation?.yield(snapshot) }
  }
}
