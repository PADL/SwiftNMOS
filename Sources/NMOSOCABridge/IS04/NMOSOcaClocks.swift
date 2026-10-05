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

/// The node's clocks as the device's media clocks and their time sources give them.
struct NMOSOcaClocks {
  /// The clocks in the order they are named, `clk0` first.
  var clocks = [NMOSClock]()
  /// The name of the clock each media clock is timed from.
  var names = [OcaONo: String]()
  /// The objects the clocks were read from, to be observed for changes.
  var objects = [SwiftOCADevice.OcaRoot]()

  func name(for endpoint: NMOSOcaEndpoint) -> String? {
    names[endpoint.endpoint.clockONo]
  }
}

extension NMOSOcaBridge {
  static let clockProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaMediaClock3.self, [
    .init(defLevel: 3, propertyIndex: 2): { $0.timeSourceONo },
  ]) + .of(SwiftOCADevice.OcaTimeSource.self, [
    .init(defLevel: 3, propertyIndex: 2): { $0.timeDeliveryMechanism },
    .init(defLevel: 3, propertyIndex: 5): { $0.referenceID },
    .init(defLevel: 3, propertyIndex: 6): { $0.syncStatus },
    .init(defLevel: 3, propertyIndex: 8): { $0.protocol },
  ])

  /// One clock for each time source the endpoints' media clocks follow, and one internal
  /// clock for each media clock that follows none. Ordered by object number, so that a
  /// clock keeps its name for as long as the same objects exist.
  func clocks(for endpoints: [NMOSOcaEndpoint]) async -> NMOSOcaClocks {
    var result = NMOSOcaClocks()
    // keyed by the object that makes the clock what it is: its time source, else itself
    var named = [OcaONo: String]()
    for clockONo in Set(endpoints.map(\.endpoint.clockONo)).sorted() where clockONo != OcaInvalidONo {
      guard let mediaClock: SwiftOCADevice.OcaMediaClock3 = await device.resolve(objectNumber: clockONo)
      else { continue }
      result.objects.append(mediaClock)
      let timeSource: SwiftOCADevice.OcaTimeSource? = await device.resolve(objectNumber: mediaClock.timeSourceONo)
      let key = timeSource?.objectNumber ?? clockONo
      if let name = named[key] {
        result.names[clockONo] = name
        continue
      }
      let name = "clk\(result.clocks.count)"
      named[key] = name
      result.names[clockONo] = name
      if let timeSource {
        result.objects.append(timeSource)
        result.clocks.append(Self.clock(named: name, from: timeSource))
      } else {
        result.clocks.append(.internal(name: name))
      }
    }
    return result
  }

  /// A time source delivered by PTP, whose grandmaster is known, is a PTP clock; any
  /// other is a clock of the node's own as far as NMOS can say.
  private static func clock(named name: String, from timeSource: SwiftOCADevice.OcaTimeSource) -> NMOSClock {
    let isPTP = [.ieee1588v2, .ieee1588v2_1, .ieee8021AS].contains(timeSource.timeDeliveryMechanism)
      || [.ieee1588_2008, .ieee_avb].contains(timeSource.protocol)
    guard isPTP, let gmid = grandmasterID(in: timeSource.referenceID) else {
      return .internal(name: name)
    }
    return .ptp(name: name, traceable: false, gmid: gmid, locked: timeSource.syncStatus == .synchronized)
  }

  /// The grandmaster identity at the start of a reference ID, as IS-04 writes it: eight
  /// lower-case octets joined by hyphens. Reference IDs separate the octets variously and
  /// may go on to give the domain; nil if there are not eight octets, or they are all zero.
  nonisolated static func grandmasterID(in referenceID: String) -> String? {
    var text = referenceID.lowercased()
    if text.hasPrefix("0x") { text.removeFirst(2) }
    let digits = Array(text.filter(\.isHexDigit).prefix(16))
    guard digits.count == 16, digits.contains(where: { $0 != "0" }) else { return nil }
    return stride(from: 0, to: 16, by: 2).map { String(digits[$0...$0 + 1]) }.joined(separator: "-")
  }
}
