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

/// The store's resources by type, as the tests read them.
extension NMOSResourceStore {
  var devices: [NMOSDeviceResource] {
    resources(.device).compactMap { if case let .device(resource) = $0 { resource } else { nil } }
  }

  var senders: [NMOSSenderResource] {
    resources(.sender).compactMap { if case let .sender(resource) = $0 { resource } else { nil } }
  }

  var receivers: [NMOSReceiverResource] {
    resources(.receiver).compactMap { if case let .receiver(resource) = $0 { resource } else { nil } }
  }

  /// A new version for a sender or receiver that has not changed, as a re-activation gives one.
  @discardableResult
  func touch(_ kind: NMOSResourceKind, id: NMOSID) -> NMOSTimestamp? {
    switch resource(kind, id: id) {
    case let .sender(sender):
      setSubscription(kind, id: id, active: sender.subscription.active, peer: sender.subscription.receiverID, touch: true)
    case let .receiver(receiver):
      setSubscription(kind, id: id, active: receiver.subscription.active, peer: receiver.subscription.senderID, touch: true)
    default:
      nil
    }
  }
}
