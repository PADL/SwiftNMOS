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
import SwiftOCADevice

extension NMOSOcaDanteAdaptation {
  /// A Dante channel is named by its device's name and its own, as a subscription names
  /// it. AES70-23 gives no ID of the device that outlives a rename, so renaming the device
  /// or the channel makes its resources new ones.
  public func nativeIdentity(of endpoint: NMOSOcaEndpoint) async -> String? {
    let device = await endpoint.application.deviceDelegate?.deviceManager?.deviceName ?? ""
    let channel = channelName(of: endpoint)
    guard !device.isEmpty, !channel.isEmpty else { return nil }
    return "dante/\(device)/\(channel)"
  }
}
