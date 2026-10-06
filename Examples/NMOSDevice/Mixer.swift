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

import SwiftOCA
import SwiftOCADevice

/// A mixer as a block of workers, so the IS-12 tree has blocks within blocks and
/// properties to read, set and be notified of: a block for each input channel with a
/// gain and a mute, and a master gain. Nothing is processed; the values are only kept.
enum Mixer {
  @OcaDevice
  static func make(channels: Int, device: OcaDevice) async throws {
    let mixer = try await SwiftOCADevice.OcaBlock(role: "Mixer", deviceDelegate: device)
    for index in 1..<(channels + 1) {
      let channel = try await SwiftOCADevice.OcaBlock(
        role: "Channel\(index)", deviceDelegate: device, addToRootBlock: false
      )
      channel.label = "Channel \(index)"
      let gain = try await SwiftOCADevice.OcaGain(role: "Gain", deviceDelegate: device, addToRootBlock: false)
      gain.gain.value = 0
      let mute = try await SwiftOCADevice.OcaMute(role: "Mute", deviceDelegate: device, addToRootBlock: false)
      mute.state = .unmuted
      try await channel.add(actionObject: gain)
      try await channel.add(actionObject: mute)
      try await mixer.add(actionObject: channel)
    }
    let master = try await SwiftOCADevice.OcaGain(role: "Master", deviceDelegate: device, addToRootBlock: false)
    master.gain.value = 0
    try await mixer.add(actionObject: master)
  }
}
