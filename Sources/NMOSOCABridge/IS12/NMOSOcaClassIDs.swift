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
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

extension OcaClassID {
  /// The fields after the leading 1, as MS-05-02 class indices. OCA's proprietary
  /// marker and the two fields of its authority become that authority's key.
  var ncIndices: NcClassID {
    let fields = fields.map { Int32($0) }.dropFirst()
    var indices = NcClassID()
    var index = fields.startIndex
    while index < fields.endIndex {
      if fields[index] == 0xFFFF, index + 2 < fields.endIndex {
        indices.append(-((fields[index + 1] & 0xFF) << 16 | fields[index + 2]))
        index += 3
      } else {
        indices.append(fields[index])
        index += 1
      }
    }
    return indices
  }

  /// The MS-05-02 level the class's elements are presented at under an anchor:
  /// N + L − 1, N being the anchor's level and L the class's OCA level.
  func ncLevel(under anchor: NcClassID) -> UInt16 {
    anchor.ncLevel + ncIndices.ncLevel
  }

  /// The classes this ID names between itself and `ancestor`, nearest the ancestor first.
  func classIDs(after ancestor: OcaClassID) -> [OcaClassID] {
    var between = [OcaClassID]()
    var parent = parent
    while let id = parent, id != ancestor, id.isSubclass(of: ancestor) {
      between.insert(id, at: 0)
      parent = id.parent
    }
    return between
  }

  /// The name of the class: that of the registered class of this ID, if there is one.
  @OcaDevice
  var className: String {
    if let type = try? OcaDeviceClassRegistry.shared.match(classID: self), type.classID == self {
      return type.className
    }
    return "OcaClass" + fields.map { String($0) }.joined(separator: "_")
  }
}

extension SwiftOCADevice.OcaRoot {
  /// The class's name without its generic arguments; `Nc` is the standard's to use.
  nonisolated static var className: String {
    let name = String(String(describing: self).prefix { $0 != "<" })
    return name.hasPrefix("Nc") ? "Oca" + name : name
  }
}

extension [OcaDeviceClassDescriptor] {
  /// The classes of a lineage whose elements, properties and methods alike, are presented:
  /// all but OcaRoot. NcObject owns level 1, so OcaRoot's elements would take the IDs of
  /// NcObject's (and, under a deeper anchor, the anchor's own); they are served by NcObject.
  var presented: some Sequence<(offset: Int, element: OcaDeviceClassDescriptor)> {
    enumerated().dropFirst()
  }
}
