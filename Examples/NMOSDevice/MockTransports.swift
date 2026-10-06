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
import SwiftOCA
import SwiftOCADevice

/// An AES67 application that moves no audio but behaves as a device's would: a sender
/// describes its stream as SDP, and a receiver configured from a description then
/// reports that description as its active one. The RTP adaptation presents it through
/// IS-05's `urn:x-nmos:transport:rtp`.
final class MockAes67Application: SwiftOCADevice.Aes67OcaMediaTransportApplication {
  private static let mode = OcaMediaStreamMode(
    frameFormat: .rtp, encodingType: "audio/L24", samplingRate: 48000, channelCount: 2, packetTime: 1e-3
  )

  /// `receivers` inputs and `senders` outputs, the outputs sending to multicast groups
  /// from `address`, on the network interface `interface`.
  static func make(
    receivers: Int,
    senders: Int,
    address: String,
    interface: SwiftOCADevice.OcaNetworkInterface,
    device: OcaDevice
  ) async throws -> MockAes67Application {
    let application = try await MockAes67Application(role: "AES67", deviceDelegate: device)
    application.networkInterfaceAssignments = [OcaNetworkInterfaceAssignment(
      id: 1, networkInterfaceONo: interface.objectNumber, networkBindingParameters: OcaBlob(),
      securityKeyIdentities: [], advertisingMechanisms: []
    )]
    for index in 1..<(receivers + 1) {
      application.insert(endpoint: OcaMediaStreamEndpoint(
        idInternal: OcaMediaStreamEndpointID(index), direction: .input, userLabel: "AES67 Rx \(index)",
        currentStreamMode: mode
      ))
    }
    for index in 1..<(senders + 1) {
      let id = OcaMediaStreamEndpointID(1000 + index)
      application.insert(endpoint: OcaMediaStreamEndpoint(
        idInternal: id, direction: .output, userLabel: "AES67 Tx \(index)", currentStreamMode: mode
      ))
      try application.setActiveSDP(sdp(from: address, group: index, label: "AES67 Tx \(index)"), endpoint: id)
    }
    return application
  }

  override func configureEndpointFromSDP(
    endpointID id: OcaMediaStreamEndpointID,
    sdpString: OcaSDPString,
    streamID: OcaUint16,
    from controller: any OcaController
  ) async throws {
    try setActiveSDP(sdpString, endpoint: id)
  }

  /// What a device does once a stream is set up: the endpoint reports its description.
  private func setActiveSDP(_ sdp: OcaSDPString, endpoint id: OcaMediaStreamEndpointID) throws {
    var endpoint = try endpoint(id)
    var data = (try? endpoint.adaptationData.decode(Aes67EndpointAdaptationData.self))
      ?? Aes67EndpointAdaptationData()
    data.activeSDP = sdp
    endpoint.adaptationData = try data.blob
    try update(endpoint: endpoint)
  }

  /// A two-channel L24 stream to 239.69.0.`group`, as AES67 describes one.
  private static func sdp(from address: String, group: Int, label: String) -> OcaSDPString {
    let session = 1_000_000 + group
    return [
      "v=0", "o=- \(session) \(session) IN IP4 \(address)", "s=\(label)", "c=IN IP4 239.69.0.\(group)/32",
      "t=0 0", "m=audio 5004 RTP/AVP 96", "a=rtpmap:96 L24/48000/2", "a=sendonly", "a=ptime:1",
      "a=ts-refclk:ptp=IEEE1588-2008:00-00-00-FF-FE-00-00-00:0", "a=mediaclk:direct=0", "",
    ].joined(separator: "\r\n")
  }
}

/// A Dante application that moves no audio but behaves as a device's would: setting a
/// receive channel's endpoint subscribes it, and the subscription then shows in the
/// channel. The Dante adaptation presents it through `urn:x-nmos:transport:dante`.
final class MockDanteApplication: SwiftOCADevice.DanteOcaMediaTransportApplication {
  static func make(receivers: Int, senders: Int, device: OcaDevice) async throws -> MockDanteApplication {
    let application = try await MockDanteApplication(role: "Dante", deviceDelegate: device)
    for index in 1..<(receivers + 1) {
      try application.addChannel(OcaID16(index), name: String(format: "%02d", index), direction: .input)
    }
    for index in 1..<(senders + 1) {
      try application.addChannel(OcaID16(1000 + index), name: "Out \(index)", direction: .output)
    }
    return application
  }

  private func addChannel(_ id: OcaID16, name: String, direction: OcaIODirection) throws {
    insert(endpoint: OcaMediaStreamEndpoint(
      idInternal: OcaMediaStreamEndpointID(id), idExternal: OcaBlob(Array(name.utf8)), direction: direction
    ))
    channelEndpoints[id] = try OcaChannelEndpoint(
      idExternal: OcaBlob(Array(name.utf8)), direction: direction,
      adaptationData: DanteChannelEndpointAdaptationData(streamEndpointID: OcaMediaStreamEndpointID(id)).blob
    )
  }

  override func setChannelEndpoint(
    id: OcaID16,
    channelEndpoint: OcaChannelEndpoint,
    from controller: any OcaController
  ) async throws {
    let remote = try channelEndpoint.adaptationData.decode(DanteChannelEndpointAdaptationData.self).remoteAddress
    try show(remote, on: id)
  }

  override func clearChannelEndpoint(id: OcaID16, from controller: any OcaController) async throws {
    try show(DanteChannelAddress(), on: id)
  }

  /// What a device reports once a subscription has taken effect, or been cleared.
  private func show(_ remote: DanteChannelAddress, on id: OcaID16) throws {
    var channel = try channelEndpoint(id)
    var data = try channel.adaptationData.decode(DanteChannelEndpointAdaptationData.self)
    data.remoteAddress = remote
    data.subscriptionStatus = remote.device.isEmpty ? .none : .subscribedToUnicastFlow
    channel.adaptationData = try data.blob
    update(channelEndpointID: id, channel)
  }
}
