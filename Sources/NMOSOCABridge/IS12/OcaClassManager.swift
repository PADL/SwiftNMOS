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
import SwiftOCAClassManager
@_spi(SwiftOCAPrivate)
import SwiftOCADevice

/// The device's class manager (see `SwiftOCAClassManager.OcaClassManager`). It describes
/// the classes of the device's objects to an OCA controller from what SwiftOCADevice
/// knows of them, and IS-12 presents it as `NcClassManager`, whose methods and
/// properties the object model answers from the classes the bridge describes.
@OcaDeviceMethods
public final class OcaClassManager: SwiftOCADevice.OcaManager {
  override public class var classID: OcaClassID { SwiftOCAClassManager.OcaClassManager.classID }

  public nonisolated static let objectNumber = SwiftOCAClassManager.OcaClassManager.objectNumber

  /// The device's class manager, made the first time it is asked for.
  static func shared(on device: OcaDevice) async throws -> OcaClassManager {
    if let existing: OcaClassManager = await device.resolve(objectNumber: objectNumber) {
      return existing
    }
    return try await OcaClassManager(
      objectNumber: objectNumber, role: "ClassManager", deviceDelegate: device, addToRootBlock: false
    )
  }

  @OcaDeviceMethod(SwiftOCAClassManager.OcaClassManager.Methods.getControlClass, access: .read)
  func getControlClass(
    classID: OcaClassID,
    includeInherited: OcaBoolean,
    from controller: any OcaController
  ) async throws -> OcaClassDescriptor {
    for object in await objects() {
      let lineage = object.deviceClassDescriptors
      guard let index = lineage.firstIndex(where: { $0.classID == classID }) else { continue }
      let classes = includeInherited ? Array(lineage[...index]) : [lineage[index]]
      return Self.descriptor(of: lineage[index], with: classes)
    }
    throw Ocp1Error.status(.parameterError)
  }

  @OcaDeviceMethod(SwiftOCAClassManager.OcaClassManager.Methods.getControlClasses, access: .read)
  func getControlClasses(from controller: any OcaController) async throws -> [OcaClassDescriptor] {
    var described = [OcaClassDescriptor]()
    var seen = Set<OcaClassID>()
    for object in await objects() {
      for oca in object.deviceClassDescriptors where seen.insert(oca.classID).inserted {
        described.append(Self.descriptor(of: oca, with: [oca]))
      }
    }
    return described
  }

  /// Every object reachable from the root block, and the managers.
  private func objects() async -> [SwiftOCADevice.OcaRoot] {
    guard let device = deviceDelegate, let root = await device.rootBlock else { return [] }
    var found: [SwiftOCADevice.OcaRoot] = [root]
    if let deviceManager = await device.deviceManager {
      for manager in deviceManager.managers {
        if let object: SwiftOCADevice.OcaRoot = await device.resolve(objectNumber: manager.objectNumber) {
          found.append(object)
        }
      }
    }
    var index = 0
    while index < found.count {
      if let block = found[index] as? any OcaBlockContainer {
        found += block.actionObjects
      }
      index += 1
    }
    return found
  }

  /// `oca` described with the elements of `classes`, which are it and, if asked for,
  /// the classes it derives from.
  private static func descriptor(
    of oca: OcaDeviceClassDescriptor,
    with classes: [OcaDeviceClassDescriptor]
  ) -> OcaClassDescriptor {
    OcaClassDescriptor(
      classID: oca.classID,
      classVersion: oca.classVersion,
      name: name(of: oca.type),
      properties: classes.flatMap(\.properties).map { property in
        OcaClassPropertyDescriptor(
          propertyID: property.propertyID,
          name: property.name,
          typeName: name(of: property.valueType),
          isReadOnly: !property.isSettable
        )
      },
      methods: classes.flatMap(\.methods).map { descriptor in
        let method = descriptor.method
        return OcaClassMethodDescriptor(
          methodID: method.methodID,
          name: method.name,
          parameters: parameters(of: method),
          resultTypeName: method.resultType.map(name(of:)) ?? ""
        )
      }
    )
  }

  /// A method's parameters: the fields of its record, or its one parameter.
  private static func parameters(of method: OcaAnyMethodDescriptor) -> [OcaClassParameterDescriptor] {
    guard let type = method.parametersType else { return [] }
    if type is any OcaParametersReflectable.Type {
      let fields = Ocp2Encoder.fields(of: type)
      return fields.enumerated().map { index, field in
        let name = method.parameterNames.flatMap { index < $0.count ? $0[index] : nil }
          ?? Ocp2Encoder.fieldName(field.name)
        return OcaClassParameterDescriptor(name: name, typeName: Self.name(of: field.type))
      }
    }
    return [OcaClassParameterDescriptor(name: method.parameterNames?.first ?? "Value", typeName: name(of: type))]
  }

  /// A Swift type's name, as a controller would recognise it.
  private static func name(of type: Any.Type) -> String {
    String(describing: type)
  }
}
