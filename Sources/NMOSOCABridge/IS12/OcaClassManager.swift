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

/// A class manager, as an OCA manager of PADL's: AES70 has none. It is an object of the
/// device like any other, so IS-12 finds it among the device's managers and presents it
/// as `NcClassManager`, whose methods and properties the object model answers from the
/// classes the bridge describes. It knows nothing of NMOS, so it could move to SwiftOCA.
public final class OcaClassManager: SwiftOCADevice.OcaManager {
  override public class var classID: OcaClassID {
    OcaClassID(parent: super.classID, authority: OcaOrganizationID((0x0A, 0xE9, 0x1B)), "1")
  }

  /// The last object number AES70 reserves, which OCA gives no object of its own.
  public nonisolated static let objectNumber: OcaONo = OcaMaximumReservedONo

  /// The device's class manager, made the first time it is asked for.
  static func shared(on device: OcaDevice) async throws -> OcaClassManager {
    if let existing: OcaClassManager = await device.resolve(objectNumber: objectNumber) {
      return existing
    }
    return try await OcaClassManager(
      objectNumber: objectNumber, role: "ClassManager", deviceDelegate: device, addToRootBlock: false
    )
  }
}
