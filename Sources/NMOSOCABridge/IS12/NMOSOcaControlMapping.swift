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
import SwiftOCA
import SwiftOCADevice

/// How an OCA device is presented as an MS-05-02 device model: what cannot be derived
/// from the device's own classes. Everything else, the names, IDs and types of the
/// properties OCA classes declare, is read from the declarations at run time.
///
/// **Classes.** An OCA class with a standard counterpart is an *anchor*. An object is
/// presented under the deepest anchor in its lineage. Its class ID is the anchor's,
/// then `authorityKey` (AES's, whose classes OCA's are), then every OCA class ID field
/// after the leading 1; an OCA proprietary marker and its authority become that
/// authority's key, so a manufacturer's class has the manufacturer's key further on. An
/// object whose OCA lineage adds no property to the anchor is presented as the standard
/// class itself.
///
/// **Levels.** An OCA element defined at OCA level L is at level L - 1 below the
/// anchor's, with its OCA index. OCA's levels are kept whole beneath the anchor, so
/// what OcaWorker has that NcWorker lacks keeps a class and a level of its own. OcaRoot
/// alone is not presented, as level 1 is NcObject's; methods follow the same rule as
/// properties, so no OCA method can take a standard method's ID (see README.md here).
public struct NMOSOcaControlMapping: Sendable {
  /// How an OCA value becomes the value of a standard property, and back.
  public enum Transform: Sendable {
    /// The same value, marshalled as the property's OCA type describes.
    case identity
    /// `OcaManufacturer` as `NcManufacturer`.
    case manufacturer
    /// `OcaProduct` as `NcProduct`.
    case product
    /// `OcaDeviceOperationalState` as `NcDeviceOperationalState`.
    case operationalState
    /// `OcaResetCause` as `NcResetCause`.
    case resetCause
  }

  /// Where the value of a standard property comes from.
  public enum Source: Sendable {
    case constant(NMOSJSONValue)
    /// An OCA property of the object; `fallback` serves an object that lacks it.
    case property(OcaPropertyID, Transform = .identity, fallback: NMOSJSONValue)
    /// A block's members, which the object model lists from the OCA property named.
    case members(OcaPropertyID)
  }

  public struct Property: Sendable {
    public var id: NcElementID
    public var source: Source

    public init(_ level: UInt16, _ index: UInt16, _ source: Source) {
      id = NcElementID(level: level, index: index)
      self.source = source
    }
  }

  /// An OCA class presented as a standard class, with the standard class's own properties.
  public struct Anchor: Sendable {
    public var oca: OcaClassID
    public var nc: NcClassID
    public var properties: [Property]

    public init(_ oca: OcaClassID, _ nc: NcClassID, _ properties: [Property] = []) {
      self.oca = oca
      self.nc = nc
      self.properties = properties
    }
  }

  public var anchors: [Anchor]
  /// The negated organisation ID of whoever defines the classes that follow the anchor.
  public var authorityKey: Int32
  /// The Swift names of the OCA properties that serve `userLabel` and `owner`.
  public var userLabelProperty: String
  public var ownerProperty: String
  /// The Swift name of the device manager's list of the device's managers.
  public var managersProperty: String
  /// MS-05-02 fixes the root block's oid and role; OCA numbers its device manager 1.
  public var rootRole: String
  public var oids: [OcaONo: NcOid]
  /// The class manager has no OCA object; this must be an object number OCA never uses.
  public var classManagerOid: NcOid

  /// The oid an OCA object is presented under.
  public func oid(of objectNumber: OcaONo) -> NcOid { oids[objectNumber] ?? objectNumber }

  /// The OCA object an oid stands for.
  public func objectNumber(of oid: NcOid) -> OcaONo {
    oids.first { $0.value == oid }?.key ?? oid
  }

  /// The mapping of OCA as AES70 defines it: AES's OUI 00-0B-5E is the authority for the
  /// OCA classes that follow a standard class.
  public static let standard = NMOSOcaControlMapping(
    anchors: [
      Anchor("1", NcStandardModel.object),
      Anchor("1.1", NcStandardModel.worker, [
        Property(2, 1, .property("2.1", fallback: true)),
      ]),
      Anchor("1.1.3", NcStandardModel.block, [
        Property(2, 1, .property("2.1", fallback: true)),
        Property(2, 2, .members("3.2")),
      ]),
      Anchor("1.1.1.21", NcStandardModel.identBeacon, [
        Property(3, 1, .property("4.1", fallback: false)),
      ]),
      Anchor("1.3", NcStandardModel.manager),
      Anchor("1.3.1", NcStandardModel.deviceManager, [
        Property(3, 1, .constant(.string(NcStandardModel.version))),
        Property(3, 2, .property("3.15", .manufacturer, fallback: ["name": "", "organizationId": .null, "website": .null])),
        Property(3, 3, .property("3.16", .product, fallback: [
          "name": "", "key": "", "revisionLevel": "", "brandName": .null, "uuid": .null, "description": .null,
        ])),
        Property(3, 4, .property("3.2", fallback: "")),
        Property(3, 5, .property("3.7", fallback: .null)),
        Property(3, 6, .property("3.4", fallback: .null)),
        Property(3, 7, .property("3.6", fallback: .null)),
        Property(3, 8, .property("3.17", .operationalState, fallback: ["generic": 0, "deviceSpecificDetails": .null])),
        Property(3, 9, .property("3.11", .resetCause, fallback: 0)),
        Property(3, 10, .property("3.12", fallback: .null)),
      ]),
    ],
    authorityKey: -0x000B5E,
    userLabelProperty: "label",
    ownerProperty: "owner",
    managersProperty: "managers",
    rootRole: "root",
    oids: [OcaRootBlockONo: NcObjectModel<NMOSOcaObjectSource>.rootOid, OcaDeviceManagerONo: OcaRootBlockONo],
    classManagerOid: OcaMaximumReservedONo
  )
}

extension NMOSOcaControlMapping.Transform {
  /// The standard value from the OCP.2 form of the OCA value.
  func standardValue(from oca: NMOSJSONValue) -> NMOSJSONValue {
    func text(_ name: String) -> NMOSJSONValue { .string(oca[name]?.stringValue ?? "") }
    func optionalText(_ name: String) -> NMOSJSONValue {
      guard let value = oca[name]?.stringValue, !value.isEmpty else { return .null }
      return .string(value)
    }

    switch self {
    case .identity:
      return oca
    case .manufacturer:
      // an organisation ID is three octets, written in hexadecimal
      let organization = oca["OrganizationID"]?.stringValue.flatMap { Int64($0, radix: 16) }
      return [
        "name": text("Name"),
        "organizationId": organization.flatMap { $0 == 0 ? nil : .integer($0) } ?? .null,
        "website": optionalText("Website"),
      ]
    case .product:
      return [
        "name": text("Name"), "key": text("ModelID"), "revisionLevel": text("RevisionLevel"),
        "brandName": optionalText("BrandName"), "uuid": optionalText("UUID"),
        "description": optionalText("Description"),
      ]
    case .operationalState:
      // OcaDeviceGenericState to NcDeviceGenericState; an OCA fault is an internal error
      let generic: Int64 = switch oca["Generic"]?.integerValue {
      case 0: 1
      case 1: 2
      case 2: 3
      case 3: 5
      default: 0
      }
      return ["generic": .integer(generic), "deviceSpecificDetails": .null]
    case .resetCause:
      // OcaResetCause counts from power-on at 0; NcResetCause keeps 0 for unknown
      guard let cause = oca.integerValue, (0...3).contains(cause) else { return 0 }
      return .integer(cause + 1)
    }
  }

  /// Whether a controller's value can be handed to the OCA setter as it is.
  var isWritable: Bool {
    if case .identity = self { true } else { false }
  }
}
