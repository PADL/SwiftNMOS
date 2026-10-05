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

extension NMOSConnectionError {
  /// What a failed AES70 method means to an NMOS client: its request was at fault, or
  /// the device was.
  init(_ error: any Error) {
    if let error = error as? NMOSConnectionError {
      self = error
      return
    }
    guard case let Ocp1Error.status(status) = error else {
      self = .failed("\(error)")
      return
    }
    self = switch status {
    case .parameterError, .parameterOutOfRange, .badFormat, .invalidRequest:
      .invalid("The device does not accept these settings (\(status))")
    case .locked:
      .locked("The endpoint is locked by another controller")
    default:
      .failed("The device answered \(status)")
    }
  }
}

/// The controller IS-05 activations are made as: the bridge itself, which calls the
/// device's methods directly and takes no notifications.
actor NMOSConnectionController: OcaController, CustomStringConvertible {
  static let shared = NMOSConnectionController()

  nonisolated var flags: OcaControllerFlags { [] }
  nonisolated var description: String { "nmos/is05" }

  func sendMessages(_ messages: [any Ocp1Message], type messageType: OcaMessageType) async throws {}
}

extension NMOSConnectionError {
  /// Dante and Milan have no transport file: IS-04 gives their senders no
  /// `manifest_href`, and a receiver is patched by its transport parameters.
  static func noTransportFile(_ transport: String) -> Self {
    .invalid("A \(transport) receiver takes no transport file; stage its `transport_params` instead")
  }
}

extension NMOSOcaEndpoint {
  static let addressProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaMediaTransportApplication.self, [
    .init(defLevel: 2, propertyIndex: 3): { $0.networkInterfaceAssignments },
  ]) + .of(SwiftOCADevice.OcaNetworkInterface.self, [.init(defLevel: 2, propertyIndex: 8): { $0.currentAdaptationData }])

  /// The IPv4 addresses of the network interfaces the endpoint's application is assigned.
  @OcaDevice
  var interfaceAddresses: [String] {
    get async {
      var addresses = [String]()
      for assignment in application.networkInterfaceAssignments {
        guard let interface: SwiftOCADevice.OcaNetworkInterface =
          await application.deviceDelegate?.resolve(objectNumber: assignment.networkInterfaceONo),
          let settings = try? interface.currentAdaptationData.decode(OcaIP4NetworkSettings.self),
          let address = settings.addressAndPrefix.split(separator: "/").first, !address.isEmpty
        else { continue }
        addresses.append(String(address))
      }
      // an application bound to no interface of its own sends and receives on the host's
      return addresses.isEmpty ? localIPv4Addresses() : addresses
    }
  }

  /// The endpoint as the application has it now, for reading back after a change.
  @OcaDevice
  var refreshed: NMOSOcaEndpoint {
    guard let current = try? application.endpoint(endpoint.idInternal) else { return self }
    return NMOSOcaEndpoint(
      application: application,
      endpoint: current,
      status: application.endpointStatuses[current.idInternal]
    )
  }
}

extension NMOSJSONValue {
  /// A string parameter, with null and the empty string both meaning there is none.
  var nonEmptyString: String? {
    guard let string = stringValue, !string.isEmpty else { return nil }
    return string
  }
}
