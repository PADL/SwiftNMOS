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

/// The classes and datatypes MS-05-02 and the control feature sets define, as the
/// descriptors a class manager publishes for them. The descriptors themselves are
/// generated from the AMWA models by `scripts/nmos/generate-ms0502.py`.
public enum NcStandardModel {
  public static let object: NcClassID = [1]
  public static let block: NcClassID = [1, 1]
  public static let worker: NcClassID = [1, 2]
  public static let manager: NcClassID = [1, 3]
  public static let deviceManager: NcClassID = [1, 3, 1]
  public static let classManager: NcClassID = [1, 3, 2]
  public static let identBeacon: NcClassID = [1, 2, 1]
  public static let statusMonitor: NcClassID = [1, 2, 2]
  public static let receiverMonitor: NcClassID = [1, 2, 2, 1]
  public static let senderMonitor: NcClassID = [1, 2, 2, 2]

  /// Every standard class, each with only what it defines itself.
  public static let classes = frameworkClasses + identificationClasses + monitoringClasses

  /// Every standard datatype, the primitives included.
  public static let datatypes = frameworkDatatypes + identificationDatatypes + monitoringDatatypes

  /// The version of MS-05-02 the descriptors are of, as `NcDeviceManager.ncVersion` states it.
  public static let version = "v1.0.0"

  public static func classDescriptor(_ classID: NcClassID) -> NcClassDescriptor? {
    classes.first { $0.classID == classID }
  }

  /// MS-05-02's own methods of a standard class and of the standard classes above it.
  public static func methodIDs(of classID: NcClassID) -> Set<NcElementID> {
    let lineage = classID.indices.compactMap { classDescriptor(Array(classID[...$0])) }
    return Set(lineage.flatMap(\.methods).map(\.id))
  }

  /// The fixed role of a standard manager class, which a class derived from it keeps.
  public static func fixedRole(of classID: NcClassID) -> String? {
    var current: NcClassID? = classID
    while let id = current {
      if let role = classDescriptor(id)?.fixedRole { return role }
      current = id.ncParent
    }
    return nil
  }
}
