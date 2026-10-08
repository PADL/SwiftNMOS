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

/// What describing one endpoint needs to know of the rest of the description.
struct NMOSOcaDescriptionContext {
  let ids: NMOSOcaResourceIDs
  let clocks: NMOSOcaClocks
  /// The names of the node's interfaces, the only ones a binding may name.
  let interfaces: Set<String>
  /// The root of the HTTP server the Connection API is served from.
  let baseURL: String?
}

public extension NMOSOcaResourceDescribing {
  /// The interfaces AES70 says the endpoint is assigned to.
  func interfaceBindings(of endpoint: NMOSOcaEndpoint) async -> [String] {
    await endpoint.interfaceNames
  }

  /// An endpoint is active while its connection is enabled, which is IS-05's
  /// `master_enable`: IS-04 and IS-05 must say the same of it. An adaptation that makes
  /// no connections has only the endpoint's status to go by.
  func isActive(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    if let connecting = self as? any NMOSOcaConnecting {
      return await (try? connecting.active(of: endpoint).masterEnable) ?? false
    }
    return endpoint.status?.state == .connected || endpoint.status?.state == .running
  }

  /// The encodings of the endpoint's stream mode capabilities.
  func mediaTypes(of endpoint: NMOSOcaEndpoint) async -> [String] {
    endpoint.mediaTypes
  }
}

extension NMOSOcaEndpoint {
  static let descriptionProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaMediaTransportApplication.self, [
    .init(defLevel: 2, propertyIndex: 1), // label
    .init(defLevel: 3, propertyIndex: 1), // ports
    .init(defLevel: 3, propertyIndex: 7), // mediaStreamModeCapabilities
  ])

  /// The audio media types AES70 says the endpoint handles: those of its stream mode
  /// capabilities, else the one it is using, else the 24-bit linear PCM all three
  /// transports carry.
  @OcaDevice
  var mediaTypes: [String] {
    let capabilities = application.mediaStreamModeCapabilities.filter {
      endpoint.streamModeCapabilityIDs.contains($0.id)
    }
    var types = [String]()
    for type in capabilities.flatMap(\.encodingTypeList) + [endpoint.currentStreamMode.encodingType]
      where type.hasPrefix("audio/") && !types.contains(type)
    {
      types.append(type)
    }
    return types.isEmpty ? ["audio/L24"] : types
  }

  /// The label of the endpoint's resources: the one a user gave it, else its external
  /// ID where that is text (a Dante channel name, an AES67 session name), else its number.
  var label: String {
    if !endpoint.userLabel.isEmpty { return endpoint.userLabel }
    let external = Data(endpoint.idExternal)
    if !external.isEmpty, let text = String(data: external, encoding: .utf8),
       text.allSatisfy({ !$0.isASCII || $0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " " })
    {
      return text
    }
    return "\(isSender ? "Sender" : "Receiver") \(endpoint.idInternal)"
  }

  /// The application's name, which says which transport an endpoint belongs to.
  @OcaDevice
  var applicationName: String {
    application.label.isEmpty ? application.role : application.label
  }

  /// One entry for each channel of the stream, labelled by the port it is mapped to.
  /// IS-04 has no source without a channel, so a stream that gives no count has one.
  @OcaDevice
  var channels: [NMOSSourceResource.Channel] {
    let mapped = endpoint.channelMap.keys.sorted()
    let count = max(1, Int(endpoint.currentStreamMode.channelCount), mapped.count)
    return (0..<count).map { index in
      let port = index < mapped.count ? endpoint.channelMap[mapped[index]]?.first : nil
      let name = port.flatMap { id in application.ports.first { $0.id == id }?.role } ?? ""
      return .init(label: name.isEmpty ? "Channel \(index + 1)" : name)
    }
  }
}

extension NMOSOcaBridge {
  private static let defaultSampleRate = 48000

  static let sampleRateProperties = NMOSOcaObservedProperties.of(SwiftOCADevice.OcaMediaClock3.self, [.init(defLevel: 3, propertyIndex: 4)])

  /// The rate of the stream, else of the media clock it is timed from.
  private func sampleRate(of endpoint: NMOSOcaEndpoint) async -> Int {
    let streamRate = endpoint.endpoint.currentStreamMode.samplingRate
    if streamRate > 0 { return Int(streamRate.rounded()) }
    let clock: SwiftOCADevice.OcaMediaClock3? = await device.resolve(objectNumber: endpoint.endpoint.clockONo)
    if let rate = clock?.currentRate.nominalRate, rate > 0 { return Int(rate.rounded()) }
    return Self.defaultSampleRate
  }

  /// The bits per sample of linear PCM, which `audio/L24` and its like name; nil for
  /// any other encoding, which IS-04 then describes as a coded flow.
  nonisolated static func bitDepth(of mediaType: String) -> Int? {
    guard mediaType.hasPrefix("audio/L") else { return nil }
    return Int(mediaType.dropFirst("audio/L".count))
  }

  private func bindings(
    of endpoint: NMOSOcaEndpoint,
    adaptation: any NMOSOcaResourceDescribing,
    context: NMOSOcaDescriptionContext
  ) async -> [String] {
    await adaptation.interfaceBindings(of: endpoint).filter(context.interfaces.contains)
  }

  /// A sender with the flow it sends and the source of that flow.
  func senderResources(
    for endpoint: NMOSOcaEndpoint,
    adaptation: any NMOSOcaResourceDescribing,
    context: NMOSOcaDescriptionContext
  ) async -> [NMOSResource] {
    let ids = context.ids
    let sourceID = endpoint.id(.source, in: ids)
    let flowID = endpoint.id(.flow, in: ids)
    let senderID = endpoint.id(.sender, in: ids)
    let label = endpoint.label
    let description = "\(endpoint.applicationName) output \(endpoint.endpoint.idInternal)"
    let mediaType = endpoint.mediaTypes[0]
    let transport = await adaptation.transport(of: endpoint)
    let isActive = await adaptation.isActive(endpoint)

    var manifestHref: String?
    if await adaptation.hasTransportFile(endpoint), let baseURL = context.baseURL {
      // a transport IS-05 v1.1 does not define is served by the Connection API from v1.2 only
      let version = NMOSConnectionAPI.earliestVersion(serving: NMOSOcaTransport.base(of: transport))
      manifestHref = "\(baseURL)/\(NMOSRouter.root)/connection/\(version)/single/senders/\(senderID)/transportfile"
    }
    return await [
      .source(NMOSSourceResource(
        id: sourceID, label: label, description: description, deviceID: ids.device,
        clockName: context.clocks.name(for: endpoint), channels: endpoint.channels
      )),
      .flow(NMOSFlowResource(
        id: flowID, label: label, description: description, sourceID: sourceID, deviceID: ids.device,
        sampleRate: .init(numerator: sampleRate(of: endpoint)), mediaType: mediaType,
        bitDepth: Self.bitDepth(of: mediaType)
      )),
      .sender(NMOSSenderResource(
        id: senderID, label: label, description: description, flowID: flowID, transport: transport,
        deviceID: ids.device, manifestHref: manifestHref,
        interfaceBindings: bindings(of: endpoint, adaptation: adaptation, context: context),
        // which receiver it sends to is the Connection API's to record, in the store
        subscription: .init(active: isActive)
      )),
    ]
  }

  func receiverResource(
    for endpoint: NMOSOcaEndpoint,
    adaptation: any NMOSOcaResourceDescribing,
    context: NMOSOcaDescriptionContext
  ) async -> NMOSReceiverResource {
    let receiverID = endpoint.id(.receiver, in: context.ids)
    return await NMOSReceiverResource(
      id: receiverID,
      label: endpoint.label,
      description: "\(endpoint.applicationName) input \(endpoint.endpoint.idInternal)",
      deviceID: context.ids.device,
      transport: adaptation.transport(of: endpoint),
      interfaceBindings: bindings(of: endpoint, adaptation: adaptation, context: context),
      // which sender it receives from is the Connection API's to record, in the store
      subscription: .init(active: adaptation.isActive(endpoint)),
      caps: .init(mediaTypes: adaptation.mediaTypes(of: endpoint))
    )
  }
}
