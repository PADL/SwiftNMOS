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

import Logging
import SwiftOCA
import SwiftOCADevice

/// An identify actuator, which IS-12 presents as an NcIdentBeacon. A controller asking
/// the device to identify itself, over OCA or IS-12, is logged where a device would
/// flash a light; it is momentary, so it goes back to inactive.
@OcaDevice
final class Identify: SwiftOCADevice.OcaIdentificationActuator {
  private static let logger = Logger(label: "com.padl.NMOSDevice.Identify")

  override func handleCommand(
    _ command: Ocp1Command,
    from controller: OcaController
  ) async throws -> Ocp1Response {
    let response = try await super.handleCommand(command, from: controller)
    if (command.methodID.defLevel, command.methodID.methodIndex) == (4, 2), active {
      Self.logger.info("identifying the device")
      active = false
    }
    return response
  }
}
