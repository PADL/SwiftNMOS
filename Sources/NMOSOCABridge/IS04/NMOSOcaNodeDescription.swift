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

extension NMOSOcaBridge {
  /// The IS-04 node: named by the device manager, reachable where the host says.
  private func nodeResource(
    ids: NMOSOcaResourceIDs,
    host: NMOSOcaHost,
    deviceManager: SwiftOCADevice.OcaDeviceManager,
    clocks: [NMOSClock] = [],
    interfaces: [NMOSNodeResource.Interface]? = nil
  ) -> NMOSNodeResource {
    NMOSNodeResource(
      id: ids.node,
      label: label(host: host, deviceManager: deviceManager),
      description: modelDescription(deviceManager),
      href: host.endpoints.first.map { "\($0.baseURL)/" } ?? "",
      hostname: host.hostname,
      api: .init(versions: [.v1_3], endpoints: host.endpoints),
      clocks: clocks,
      interfaces: interfaces ?? host.interfaces
    )
  }

  private static let deviceManagerProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaDeviceManager.self, [
    .init(defLevel: 3, propertyIndex: 3), // modelDescription
    .init(defLevel: 3, propertyIndex: 4), // deviceName
  ])

  /// What describing the device reads of its objects, each part declared beside its reads.
  static var observedProperties: NMOSOcaObservedProperties {
    deviceManagerProperties + clockProperties + sampleRateProperties + interfaceProperties
      + NMOSOcaEndpoint.descriptionProperties + NMOSOcaEndpoint.interfaceProperties
  }

  private func modelDescription(_ deviceManager: SwiftOCADevice.OcaDeviceManager) -> String {
    let model = deviceManager.modelDescription
    return [model.manufacturer, model.name].filter { !$0.isEmpty }.joined(separator: " ")
  }

  private func label(host: NMOSOcaHost, deviceManager: SwiftOCADevice.OcaDeviceManager) -> String {
    let name = deviceManager.deviceName
    return name.isEmpty ? (host.hostname ?? modelDescription(deviceManager)) : name
  }

  /// Everything IS-04 says about the device: its node, its one device, and a sender with
  /// its source and flow, or a receiver, for each stream endpoint an adaptation presents.
  func resources(
    ids: NMOSOcaResourceIDs,
    host: NMOSOcaHost,
    deviceManager: SwiftOCADevice.OcaDeviceManager
  ) async -> [NMOSResource] {
    let endpoints = await walker.endpoints
    let clocks = await clocks(for: endpoints)
    let interfaces = await interfaces(host: host)
    let context = NMOSOcaDescriptionContext(
      ids: ids,
      clocks: clocks,
      interfaces: Set(interfaces.map(\.name)),
      baseURL: host.endpoints.first?.baseURL
    )

    var resources = [NMOSResource.node(nodeResource(
      ids: ids, host: host, deviceManager: deviceManager, clocks: clocks.clocks, interfaces: interfaces
    ))]
    for endpoint in endpoints {
      // a transport no adaptation describes cannot be presented, so it is left out
      guard let adaptation = await adaptations.adaptation(for: endpoint) else { continue }
      if endpoint.isSender {
        resources += await senderResources(for: endpoint, adaptation: adaptation, context: context)
      } else {
        await resources.append(.receiver(receiverResource(for: endpoint, adaptation: adaptation, context: context)))
      }
    }

    // the device's deprecated lists of its senders and receivers are left empty: they
    // are found by their `device_id`, and the device does not change when they do
    resources.append(.device(NMOSDeviceResource(
      id: ids.device,
      label: label(host: host, deviceManager: deviceManager),
      description: modelDescription(deviceManager),
      nodeID: ids.node,
      controls: host.endpoints.flatMap { endpoint in controls.map { $0.deviceControl(at: endpoint) } }
    )))
    return resources
  }

  /// Yields whenever something the description is made from changes: the device manager,
  /// what the endpoint walker observes, and the clocks and time sources of the endpoints.
  nonisolated func changes() -> AsyncStream<Void> {
    walker.changes { await self.describedObjects }
  }

  /// The endpoints say which clocks there are, so the walker's changes may change these.
  private var describedObjects: [SwiftOCADevice.OcaRoot] {
    get async {
      let deviceManager: [SwiftOCADevice.OcaRoot] = await device.deviceManager.map { [$0] } ?? []
      return await deviceManager + clocks(for: walker.endpoints).objects
    }
  }
}
