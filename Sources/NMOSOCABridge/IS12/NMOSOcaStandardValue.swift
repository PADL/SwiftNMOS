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

/// An OCA type that a standard property presents as an MS-05-02 type of its own, as
/// NcDeviceManager presents `OcaManufacturer` as `NcManufacturer`. Such a property is
/// read only: the standard value is not one the OCA setter takes.
protocol NMOSOcaStandardValue: Sendable {
  /// The standard value from the OCP.2 form of the OCA value.
  static func standardValue(from oca: NMOSJSONValue) -> NMOSJSONValue
}

private extension NMOSJSONValue {
  func text(_ name: String) -> NMOSJSONValue { .string(self[name]?.stringValue ?? "") }

  func optionalText(_ name: String) -> NMOSJSONValue {
    guard let value = self[name]?.stringValue, !value.isEmpty else { return .null }
    return .string(value)
  }
}

extension OcaManufacturer: NMOSOcaStandardValue {
  static func standardValue(from oca: NMOSJSONValue) -> NMOSJSONValue {
    // an organisation ID is three octets, written in hexadecimal
    let organization = oca["OrganizationID"]?.stringValue.flatMap { Int64($0, radix: 16) }
    return [
      "name": oca.text("Name"),
      "organizationId": organization.flatMap { $0 == 0 ? nil : .integer($0) } ?? .null,
      "website": oca.optionalText("Website"),
    ]
  }
}

extension OcaProduct: NMOSOcaStandardValue {
  static func standardValue(from oca: NMOSJSONValue) -> NMOSJSONValue {
    [
      "name": oca.text("Name"), "key": oca.text("ModelID"), "revisionLevel": oca.text("RevisionLevel"),
      "brandName": oca.optionalText("BrandName"), "uuid": oca.optionalText("UUID"),
      "description": oca.optionalText("Description"),
    ]
  }
}

extension OcaDeviceOperationalState: NMOSOcaStandardValue {
  static func standardValue(from oca: NMOSJSONValue) -> NMOSJSONValue {
    // OcaDeviceGenericState to NcDeviceGenericState; an OCA fault is an internal error
    let generic: Int64 = switch oca["Generic"]?.integerValue {
    case 0: 1
    case 1: 2
    case 2: 3
    case 3: 5
    default: 0
    }
    return ["generic": .integer(generic), "deviceSpecificDetails": .null]
  }
}

extension OcaResetCause: NMOSOcaStandardValue {
  static func standardValue(from oca: NMOSJSONValue) -> NMOSJSONValue {
    // OcaResetCause counts from power-on at 0; NcResetCause keeps 0 for unknown
    guard let cause = oca.integerValue, (0...3).contains(cause) else { return 0 }
    return .integer(cause + 1)
  }
}
