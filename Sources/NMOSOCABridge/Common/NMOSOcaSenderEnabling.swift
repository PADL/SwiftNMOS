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

/// A media transport application that can stop and restart a sending endpoint's
/// transmission, which AES70 does not model for every transport: AES70-22 has no method
/// for IEEE 1722.1 START_STREAMING and STOP_STREAMING on a STREAM_OUTPUT. The bridge drives
/// a sender's IS-05 `master_enable` through it; a sender of an application that does not
/// adopt it is always enabled, and a request to disable it fails.
///
/// The bridge reads the state each time it describes the device. A change made elsewhere,
/// by another controller, reaches IS-04 when the host calls `NMOSOcaBridge.describe()`.
@OcaDevice
public protocol NMOSOcaSenderEnabling: AnyObject {
  /// Whether the sending endpoint transmits when it has a destination; true for an
  /// endpoint the application has never been told to stop.
  func isSenderEnabled(_ id: OcaMediaStreamEndpointID) -> Bool

  /// Starts or stops the sending endpoint's transmission. Throws, as an AES70 method
  /// does, when the endpoint is unknown or the device refuses.
  func setSenderEnabled(_ id: OcaMediaStreamEndpointID, _ enabled: Bool) async throws
}
