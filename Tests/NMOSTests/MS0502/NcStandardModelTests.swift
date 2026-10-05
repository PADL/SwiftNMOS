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
import XCTest

/// The generated descriptors against the AMWA models they were generated from, which
/// `scripts/nmos/fetch-specs.sh` puts in `.build/nmos-specs`.
final class NcStandardModelTests: XCTestCase {
  private static let specifications = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/nmos-specs")

  /// The model files of every specification the descriptors are generated from.
  private func models(_ kind: String) throws -> [NMOSJSONValue] {
    let directories = [
      "ms-05-02/models", "nmos-control-feature-sets/identification/models",
      "nmos-control-feature-sets/monitoring/models",
    ].map { Self.specifications.appendingPathComponent($0).appendingPathComponent(kind) }
    guard FileManager.default.fileExists(atPath: directories[0].path) else {
      throw XCTSkip("the specifications have not been fetched; run scripts/nmos/fetch-specs.sh")
    }
    // a feature set with no datatypes of its own has no directory for them
    return try directories.filter { FileManager.default.fileExists(atPath: $0.path) }.flatMap { directory in
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .map { try NMOSJSONValue(data: Data(contentsOf: $0)) }
    }
  }

  func testClassDescriptorsAreThoseOfTheSpecifications() throws {
    let models = try models("classes")
    XCTAssertEqual(models.count, NcStandardModel.classes.count)
    for model in models {
      let classID = try XCTUnwrap(model["classId"].flatMap(NcClassID.init(json:)))
      let descriptor = try XCTUnwrap(NcStandardModel.classDescriptor(classID), "\(classID)")
      XCTAssertEqual(descriptor.json, model, "\(classID)")
    }
  }

  func testDatatypeDescriptorsAreThoseOfTheSpecifications() throws {
    let models = try models("datatypes")
    let generated = Dictionary(uniqueKeysWithValues: NcStandardModel.datatypes.map { ($0.name, $0) })
    for model in models {
      let name = try XCTUnwrap(model["name"]?.stringValue)
      XCTAssertEqual(generated[name]?.json, model, name)
    }
    // what the models leave to prose: the ten primitives
    let primitives = NcStandardModel.datatypes.filter { $0.kind == .primitive }.map(\.name)
    XCTAssertEqual(primitives.count, 10)
    XCTAssertEqual(generated.count, models.count + primitives.count)
  }

  func testEveryTypeADescriptorNamesIsDescribed() {
    let described = Set(NcStandardModel.datatypes.map(\.name))
    for descriptor in NcStandardModel.classes {
      for name in descriptor.properties.compactMap(\.typeName)
        + descriptor.methods.map(\.resultDatatype)
        + descriptor.methods.flatMap(\.parameters).compactMap(\.typeName)
        + descriptor.events.map(\.eventDatatype)
      {
        XCTAssertTrue(described.contains(name), "\(descriptor.name) names \(name)")
      }
    }
    for datatype in NcStandardModel.datatypes {
      switch datatype.kind {
      case let .typedef(parentType, _):
        XCTAssertTrue(described.contains(parentType), "\(datatype.name) names \(parentType)")
      case let .struct(fields, parentType):
        for name in fields.compactMap(\.typeName) + [parentType].compactMap(\.self) {
          XCTAssertTrue(described.contains(name), "\(datatype.name) names \(name)")
        }
      case .primitive, .enum:
        break
      }
    }
  }

  func testClassIDsGiveLineageAndLevel() {
    XCTAssertNil(NcStandardModel.object.ncParent)
    XCTAssertEqual(NcStandardModel.receiverMonitor.ncParent, NcStandardModel.statusMonitor)
    XCTAssertEqual(NcStandardModel.receiverMonitor.ncLevel, 4)
    // an authority key is neither a class nor a level
    let vendor: NcClassID = [1, 2, -715_035, 1, 5]
    XCTAssertTrue(vendor.isNonStandard)
    XCTAssertEqual(vendor.ncLevel, 4)
    XCTAssertEqual(vendor.ncParent, [1, 2, -715_035, 1])
    XCTAssertEqual(vendor.ncParent?.ncParent, NcStandardModel.worker)
    XCTAssertFalse(NcStandardModel.worker.isNonStandard)
    XCTAssertEqual(NcStandardModel.fixedRole(of: [1, 3, 1, 0, 1]), "DeviceManager")
    XCTAssertNil(NcStandardModel.fixedRole(of: NcStandardModel.worker))
  }
}
