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

import NMOS
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
import Synchronization

/// The controller a control session is to the device. It speaks OCP.2, so that values
/// arrive as JSON, and is named for the session's peer, which is what the device's
/// logs and locks know it by. Only a peer on a local socket is a local controller.
actor NMOSOcaControlController: OcaController, CustomStringConvertible {
  typealias Changed = @Sendable (OcaONo, OcaPropertyID) async -> Void

  nonisolated let flags: OcaControllerFlags
  nonisolated let description: String
  nonisolated var controlProtocol: OcaControlProtocol { .ocp2 }
  private let changed: Changed

  init(description: String, flags: OcaControllerFlags, changed: @escaping Changed) {
    self.description = description
    self.flags = flags
    self.changed = changed
  }

  /// As SwiftOCA has its own network controllers: one that can hold locks, and local
  /// only if it reached the device through a socket of the host's file system.
  init(session: NcSession, changed: @escaping Changed) {
    switch session.peer {
    case .local:
      self.init(description: "ncp/local/\(session)", flags: [.supportsLocking, .isLocal], changed: changed)
    case .ip, nil:
      self.init(description: "ncp/tcp/\(session)", flags: .supportsLocking, changed: changed)
    }
  }

  /// The only messages a device sends a controller unasked are notifications. Which
  /// object and property one is about is all that is taken from it, without decoding its
  /// value: the value is read afresh, the way the session's own Get would read it.
  func sendMessages(_ messages: [any Ocp1Message], type messageType: OcaMessageType) async throws {
    guard messageType == .ocaNtf2 else { return }
    for case let notification as Ocp1Notification2 in messages
      where notification.event.eventID == OcaPropertyChangedEventID
    {
      let property = try OcaEventDataCoding.propertyID(from: notification.eventData)
      await changed(notification.event.emitterONo, property)
    }
  }
}

/// Where the device finds the controllers of the open control sessions, to notify them.
final class NMOSOcaControlEndpoint: OcaDeviceEndpoint {
  private let sessions = Mutex([NMOSOcaControlController]())

  func add(_ controller: NMOSOcaControlController) {
    sessions.withLock { $0.append(controller) }
  }

  func remove(_ controller: NMOSOcaControlController) {
    sessions.withLock { $0.removeAll { $0 === controller } }
  }

  var controllers: [any OcaController] {
    get async { sessions.withLock { $0 } }
  }
}
