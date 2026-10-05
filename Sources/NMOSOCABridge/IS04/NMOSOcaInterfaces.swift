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

extension SwiftOCADevice.OcaNetworkInterface {
  nonisolated static let nmosNameProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaNetworkInterface.self, [
    .init(defLevel: 2, propertyIndex: 1): { $0.label },
    .init(defLevel: 2, propertyIndex: 4): { $0.systemIOInterfaceName },
  ])
}

public extension SwiftOCADevice.OcaNetworkInterface {
  /// What the node calls this interface: its system name where it has one, as that is
  /// what the host's own list of interfaces uses.
  var nmosName: String {
    [systemIOInterfaceName, label, role].first { !$0.isEmpty } ?? "\(objectNumber)"
  }
}

public extension OcaMacAddress {
  /// Six lower-case hyphen-separated octets, as IS-04 writes a `port_id`. The one place
  /// a MAC address is written for NMOS; resource IDs are seeded from it, so it is fixed.
  var nmosString: String {
    let octets = [eui48.0, eui48.1, eui48.2, eui48.3, eui48.4, eui48.5]
    return octets.map { String(format: "%02x", $0) }.joined(separator: "-")
  }
}

extension NMOSOcaBridge {
  static let interfaceProperties = SwiftOCADevice.OcaNetworkInterface.nmosNameProperties
    + .of(SwiftOCADevice.OcaNetworkInterface.self, [
      .init(defLevel: 2, propertyIndex: 7): { $0.adaptationIdentifier },
      .init(defLevel: 2, propertyIndex: 8): { $0.currentAdaptationData },
    ])

  /// The node's interfaces: those the host names, then any OCA network interface that
  /// gives its own MAC address. IS-04 requires the address, and the IP adaptations do
  /// not carry it, so an interface known only to OCA and without one is left out.
  func interfaces(host: NMOSOcaHost) async -> [NMOSNodeResource.Interface] {
    var interfaces = host.interfaces
    var names = Set(interfaces.map(\.name))
    for interface in await walker.networkInterfaces where !names.contains(interface.nmosName) {
      guard interface.adaptationIdentifier == MilanAdaptation.identifier,
            let data = try? MilanNetworkInterfaceAdaptationData(blob: interface.currentAdaptationData),
            data.macAddress != .zero else { continue }
      names.insert(interface.nmosName)
      interfaces.append(.init(name: interface.nmosName, chassisID: nil, portID: data.macAddress.nmosString))
    }
    return interfaces
  }
}

extension NMOSOcaEndpoint {
  static let interfaceProperties = SwiftOCADevice.OcaNetworkInterface.nmosNameProperties
    + .of(SwiftOCADevice.OcaMediaTransportApplication.self, [.init(defLevel: 2, propertyIndex: 3): { $0.networkInterfaceAssignments }])

  /// The names of the network interfaces the endpoint is assigned to, one per leg: those
  /// its own assignment IDs select, or every assignment of the application if it has none.
  @OcaDevice
  var interfaceNames: [String] {
    get async {
      let assignments = application.networkInterfaceAssignments.filter {
        endpoint.networkAssignmentIDs.isEmpty || endpoint.networkAssignmentIDs.contains($0.id)
      }
      var names = [String]()
      for assignment in assignments {
        let interface: SwiftOCADevice.OcaNetworkInterface? =
          await application.deviceDelegate?.resolve(objectNumber: assignment.networkInterfaceONo)
        if let interface { names.append(interface.nmosName) }
      }
      return names
    }
  }
}
