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
import Synchronization

/// Where the bridge keeps the user labels of objects that have no OCA label a controller
/// can set, such as managers, or whose device will not change theirs. MS-05-02 has every
/// object's label writable, and has it persist across a restart, which a host's store can.
public protocol NMOSOcaLabelStore: Sendable {
  func label(of objectNumber: OcaONo) async -> String?
  /// Keeps `label` for the object, or forgets the object's label if it is nil.
  func setLabel(_ label: String?, of objectNumber: OcaONo) async
}

/// Labels kept in memory, for as long as the process runs.
public final class NMOSOcaMemoryLabelStore: NMOSOcaLabelStore {
  private let labels = Mutex([OcaONo: String]())

  public init() {}

  public func label(of objectNumber: OcaONo) -> String? { labels.withLock { $0[objectNumber] } }

  public func setLabel(_ label: String?, of objectNumber: OcaONo) { labels.withLock { $0[objectNumber] = label } }
}
