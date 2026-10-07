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

/// RTP endpoints are connected by exchanging SDP. An AES67 application carries the
/// active description in its endpoints' adaptation data and takes a new one through
/// ConfigureEndpointFromSDP; any other application does both through
/// `MediaStreamEndpointSDPRepresentable`.
extension NMOSOcaRTPAdaptation: NMOSOcaConnecting {
  /// RFC 3551's default RTP port, for an endpoint that has not been given one.
  private static let defaultPort: Int64 = 5004
  private static let unspecifiedAddress = "0.0.0.0"

  public func transportType(of endpoint: NMOSOcaEndpoint) async -> String { NMOSOcaTransport.rtp }

  // MARK: Reading

  /// The AES67 adaptation data is the endpoint's; the addresses its interfaces'.
  public var connectionProperties: NMOSOcaObservedProperties {
    .of(SwiftOCADevice.OcaMediaTransportApplication.self, [.init(defLevel: 3, propertyIndex: 10)])
      + NMOSOcaEndpoint.addressProperties
  }

  private func adaptationData(of endpoint: NMOSOcaEndpoint) -> Aes67EndpointAdaptationData? {
    guard endpoint.application is SwiftOCADevice.Aes67OcaMediaTransportApplication else { return nil }
    return try? endpoint.endpoint.adaptationData.decode(Aes67EndpointAdaptationData.self)
  }

  /// The description of the stream the endpoint carries, empty when it carries none.
  private func activeSDPString(of endpoint: NMOSOcaEndpoint) async -> OcaSDPString {
    if let data = adaptationData(of: endpoint) { return data.activeSDP }
    guard let application = endpoint.application as? any MediaStreamEndpointSDPRepresentable else { return "" }
    return await (try? application.getActiveSDP(endpoint.endpoint.idInternal)) ?? ""
  }

  private func activeSDP(of endpoint: NMOSOcaEndpoint) async -> MediaStreamSDP? {
    let text = await activeSDPString(of: endpoint)
    return MediaStreamSDP.streams(in: text).lazy.compactMap { MediaStreamSDP(sdpString: $0) }.first
  }

  public func active(of endpoint: NMOSOcaEndpoint) async throws -> NMOSConnectionState {
    let sdp = await activeSDP(of: endpoint)
    let interfaces = await endpoint.interfaceAddresses
    let ip = adaptationData(of: endpoint)?.ipParameters.first
    let port = sdp.map { Int64($0.destinationPort) } ?? Self.defaultPort

    var parameters: NMOSTransportParameters
    if endpoint.isSender {
      let sourcePort = ip.map { Int64($0.sourcePort) }.flatMap { $0 == 0 ? nil : $0 } ?? port
      parameters = [
        "source_ip": .string(sdp?.sourceAddress ?? sdp?.originAddress ?? interfaces.first ?? Self.unspecifiedAddress),
        "destination_ip": .string(sdp?.destinationAddress ?? Self.unspecifiedAddress),
        "source_port": .integer(sourcePort),
        "destination_port": .integer(port),
      ]
    } else {
      parameters = Self.receiverParameters(sdp, interfaces: interfaces)
    }
    // with one leg there is nothing for this to say that `master_enable` does not
    parameters["rtp_enabled"] = true
    return NMOSConnectionState(masterEnable: sdp != nil, transportParameters: [parameters])
  }

  /// What a receiver's parameters are when it receives the described stream; with no
  /// description, what an unconfigured receiver presents.
  private static func receiverParameters(_ sdp: MediaStreamSDP?, interfaces: [String]) -> NMOSTransportParameters {
    guard let sdp else {
      return [
        "source_ip": .null, "multicast_ip": .null, "destination_port": .integer(defaultPort),
        "interface_ip": interfaces.first.map { .string($0) } ?? "auto",
      ]
    }
    // a unicast stream is addressed to the interface it arrives on
    let interface = sdp.isMulticast
      ? interfaces.first
      : (interfaces.contains(sdp.destinationAddress) ? sdp.destinationAddress : interfaces.first)
    return [
      "source_ip": sdp.sourceAddress.map { .string($0) } ?? .null,
      "multicast_ip": sdp.isMulticast ? .string(sdp.destinationAddress) : .null,
      "destination_port": .integer(Int64(sdp.destinationPort)),
      "interface_ip": interface.map { .string($0) } ?? "auto",
    ]
  }

  public func constraints(of endpoint: NMOSOcaEndpoint) async throws -> [[String: NMOSConstraint]] {
    guard !endpoint.isSender else {
      // a sender's stream is set up outside NMOS, so each parameter is what it is
      return try await active(of: endpoint).transportParameters.map { $0.mapValues { .fixed($0) } }
    }
    let interfaces = await endpoint.interfaceAddresses
    return [[
      "source_ip": .init(), "multicast_ip": .init(), "destination_port": .init(), "rtp_enabled": .fixed(true),
      "interface_ip": interfaces.isEmpty ? .init() : .init(enum: interfaces.map { .string($0) }),
    ]]
  }

  public func transportFile(of endpoint: NMOSOcaEndpoint) async throws -> NMOSTransportFile? {
    let text = await activeSDPString(of: endpoint)
    return text.isEmpty ? nil : NMOSTransportFile(data: text, type: NMOSTransportFile.sdpType)
  }

  // MARK: Transport files

  /// The stream of a transport file a single-legged receiver takes: the first one.
  private func stream(of file: NMOSTransportFile) throws -> (text: OcaSDPString, sdp: MediaStreamSDP) {
    guard file.type == nil || file.type == NMOSTransportFile.sdpType, let data = file.data else {
      throw NMOSConnectionError.invalid("An RTP receiver's transport file must be `application/sdp`")
    }
    for text in MediaStreamSDP.streams(in: data) {
      if let sdp = MediaStreamSDP(sdpString: text) { return (text, sdp) }
    }
    throw NMOSConnectionError.invalid("The transport file does not describe a linear PCM audio stream")
  }

  public func transportParameters(
    from file: NMOSTransportFile,
    for endpoint: NMOSOcaEndpoint
  ) async throws -> [NMOSTransportParameters]? {
    var parameters = try await Self.receiverParameters(stream(of: file).sdp, interfaces: endpoint.interfaceAddresses)
    // the file does not say which interface to receive on
    parameters["interface_ip"] = "auto"
    return [parameters]
  }

  // MARK: Activation

  public func activate(_ endpoint: NMOSOcaEndpoint, staged: NMOSConnectionState) async throws {
    guard !endpoint.isSender else {
      // the constraints admit only what the sender is already doing
      guard try await staged.masterEnable == active(of: endpoint).masterEnable else {
        throw NMOSConnectionError.invalid("This sender is enabled and disabled where its stream is set up")
      }
      return
    }
    guard staged.masterEnable else {
      return try await configure(endpoint, sdpString: "", streamID: 0)
    }
    let parameters = staged.transportParameters.first ?? [:]
    let (text, streamID) = try await description(for: endpoint, staged: staged, parameters)
    try await configure(endpoint, sdpString: text, streamID: streamID)
  }

  /// The description to subscribe with. A staged transport file is passed through
  /// untouched unless the staged parameters say otherwise, in which case they win.
  private func description(
    for endpoint: NMOSOcaEndpoint,
    staged: NMOSConnectionState,
    _ parameters: NMOSTransportParameters
  ) async throws -> (OcaSDPString, OcaUint16) {
    var original: (text: OcaSDPString, sdp: MediaStreamSDP)?
    if let file = staged.transportFile, file.data != nil {
      original = try stream(of: file)
    }
    // without a file, the stream it already receives or its stream mode says what to expect
    var sdp: MediaStreamSDP
    if let original {
      sdp = original.sdp
    } else if let current = await activeSDP(of: endpoint) {
      sdp = current
    } else {
      sdp = Self.template(for: endpoint)
    }

    if let multicast = parameters["multicast_ip"]?.nonEmptyString {
      sdp.destinationAddress = multicast
    } else if sdp.isMulticast || original == nil {
      // unicast: the stream is addressed to this receiver
      var interface = parameters["interface_ip"]?.nonEmptyString.flatMap { $0 == "auto" ? nil : $0 }
      if interface == nil { interface = await endpoint.interfaceAddresses.first }
      guard let interface else {
        throw NMOSConnectionError.invalid("A unicast stream needs an `interface_ip` to be received on")
      }
      sdp.destinationAddress = interface
    }
    if let port = parameters["destination_port"]?.integerValue {
      sdp.destinationPort = UInt16(clamping: port)
    }
    sdp.sourceAddress = parameters["source_ip"]?.nonEmptyString
    sdp.direction = .receiveOnly

    if let original, original.sdp.destinationAddress == sdp.destinationAddress,
       original.sdp.destinationPort == sdp.destinationPort, original.sdp.sourceAddress == sdp.sourceAddress
    {
      // nothing the parameters say differs from the file, so the device gets the file
      return (original.text, original.sdp.destinationPort)
    }
    return (sdp.sdpString, sdp.destinationPort)
  }

  /// A description in the endpoint's current stream mode, for a receiver that is given
  /// only an address to listen on.
  private static func template(for endpoint: NMOSOcaEndpoint) -> MediaStreamSDP {
    let mode = endpoint.endpoint.currentStreamMode
    let sampleSize = mode.encodingType.split(separator: "/").last
      .flatMap { $0.hasPrefix("L") ? UInt8($0.dropFirst()) : nil } ?? 24
    return MediaStreamSDP(
      sessionID: UInt64(Date().timeIntervalSince1970),
      sessionVersion: 0,
      originAddress: unspecifiedAddress,
      sessionName: endpoint.endpoint.userLabel.isEmpty ? "NMOS" : endpoint.endpoint.userLabel,
      destinationAddress: unspecifiedAddress,
      destinationPort: UInt16(defaultPort),
      payloadType: sampleSize == 16 ? 96 : 97,
      sampleSize: sampleSize,
      sampleRate: UInt32(exactly: mode.samplingRate.rounded()).flatMap { $0 > 0 ? $0 : nil } ?? 48000,
      channelCount: mode.channelCount > 0 ? mode.channelCount : 2,
      packetTime: mode.packetTime > 0 && mode.packetTime.isFinite ? mode.packetTime : 1e-3,
      direction: .receiveOnly
    )
  }

  private func configure(_ endpoint: NMOSOcaEndpoint, sdpString: OcaSDPString, streamID: OcaUint16) async throws {
    let id = endpoint.endpoint.idInternal
    do {
      switch endpoint.application {
      case let application as any MediaStreamEndpointSDPRepresentable:
        try await application.configureEndpointFromSDP(
          endpointID: id, sdpString: sdpString, streamID: streamID, from: NMOSConnectionController.shared
        )
      case let application as SwiftOCADevice.Aes67OcaMediaTransportApplication:
        try await application.configureEndpointFromSDP(
          endpointID: id, sdpString: sdpString, streamID: streamID, from: NMOSConnectionController.shared
        )
      default:
        throw NMOSConnectionError.failed("The endpoint's application takes no session description")
      }
    } catch {
      throw NMOSConnectionError(error)
    }
  }
}
