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

/// Native Dante channels (AES70-23). A receive channel is connected by naming the
/// transmit channel it subscribes to, so those two names are its transport parameters,
/// and a transmit channel's parameters are the names a receiver would subscribe with.
extension NMOSOcaDanteAdaptation: NMOSOcaConnecting {
  private static let deviceName = "device_name"
  private static let channelName = "channel_name"

  /// How long a subscription is given to appear in the device's own state.
  private static let settleTime = Duration.seconds(2)
  /// The application's channel endpoints, where a subscription appears.
  private static let channelEndpointsID = OcaPropertyID(defLevel: 4, propertyIndex: 1)

  public func transportType(of endpoint: NMOSOcaEndpoint) async -> String { NMOSOcaTransport.dante }

  // MARK: Reading

  /// A sender is named by the device; a channel is read from its channel endpoint.
  public var connectionProperties: NMOSOcaObservedProperties {
    .of(SwiftOCADevice.OcaDeviceManager.self, [.init(defLevel: 3, propertyIndex: 4)])
      + .of(SwiftOCADevice.DanteOcaMediaTransportApplication.self, [Self.channelEndpointsID])
  }

  private func streamEndpointID(of channel: OcaChannelEndpoint) -> OcaMediaStreamEndpointID? {
    (try? channel.adaptationData.decode(DanteChannelEndpointAdaptationData.self))?.streamEndpointID
  }

  /// The channel endpoint that is this stream endpoint: the one with its number, unless
  /// that names another stream endpoint and some other names this one. Every connection
  /// is read through here, so the others are looked through only when its number fails.
  private func channelEndpoint(of endpoint: NMOSOcaEndpoint) -> (id: OcaID16, channel: OcaChannelEndpoint)? {
    guard let application = endpoint.application as? SwiftOCADevice.DanteOcaMediaTransportApplication
    else { return nil }
    let id = endpoint.endpoint.idInternal
    let numbered = OcaID16(exactly: id).flatMap { key in application.channelEndpoints[key].map { (key, $0) } }
    // a channel endpoint that names no stream endpoint leaves the field zero
    if let numbered, [id, 0].contains(streamEndpointID(of: numbered.1) ?? 0) { return numbered }
    let named = application.channelEndpoints.first { streamEndpointID(of: $0.value) == id }
    return named.map { ($0.key, $0.value) } ?? numbered
  }

  private func remoteAddress(of channel: OcaChannelEndpoint?) -> DanteChannelAddress {
    (try? channel?.adaptationData.decode(DanteChannelEndpointAdaptationData.self))?.remoteAddress
      ?? DanteChannelAddress()
  }

  /// The name receivers subscribe to a transmit channel by: its external ID as text.
  private func ownChannelName(of endpoint: NMOSOcaEndpoint) -> String {
    let external = channelEndpoint(of: endpoint)?.channel.idExternal ?? endpoint.endpoint.idExternal
    let name = String(decoding: external, as: UTF8.self)
    return name.isEmpty ? endpoint.endpoint.userLabel : name
  }

  public func active(of endpoint: NMOSOcaEndpoint) async throws -> NMOSConnectionState {
    if endpoint.isSender {
      let device = await endpoint.application.deviceDelegate?.deviceManager?.deviceName ?? ""
      return NMOSConnectionState(masterEnable: true, transportParameters: [[
        Self.deviceName: .string(device), Self.channelName: .string(ownChannelName(of: endpoint)),
      ]])
    }
    let remote = remoteAddress(of: channelEndpoint(of: endpoint)?.channel)
    let subscribed = !remote.device.isEmpty && !remote.channel.isEmpty
    return NMOSConnectionState(masterEnable: subscribed, transportParameters: [[
      Self.deviceName: subscribed ? .string(remote.device) : .null,
      Self.channelName: subscribed ? .string(remote.channel) : .null,
    ]])
  }

  public func constraints(of endpoint: NMOSOcaEndpoint) async throws -> [[String: NMOSConstraint]] {
    guard !endpoint.isSender else {
      return try await active(of: endpoint).transportParameters.map { $0.mapValues { .fixed($0) } }
    }
    // a pattern says the parameters are strings, which a controller editing a cleared
    // (null) one cannot otherwise tell; Dante names are up to 31 characters, and a
    // channel's cannot contain the "@" that joins it to a device name
    return [[
      Self.deviceName: .init(pattern: Self.deviceNamePattern),
      Self.channelName: .init(pattern: Self.channelNamePattern),
    ]]
  }

  private static let deviceNamePattern = "^[A-Za-z0-9-]{1,31}$"
  private static let channelNamePattern = "^[^@]{1,31}$"

  public func transportFile(of endpoint: NMOSOcaEndpoint) async throws -> NMOSTransportFile? { nil }

  public func transportParameters(
    from file: NMOSTransportFile,
    for endpoint: NMOSOcaEndpoint
  ) async throws -> [NMOSTransportParameters]? {
    throw NMOSConnectionError.noTransportFile("Dante")
  }

  // MARK: Activation

  public func activate(_ endpoint: NMOSOcaEndpoint, staged: NMOSConnectionState) async throws {
    guard !endpoint.isSender else {
      guard staged.masterEnable else {
        throw NMOSConnectionError.invalid("A Dante transmit channel cannot be disabled")
      }
      return
    }
    guard let application = endpoint.application as? SwiftOCADevice.DanteOcaMediaTransportApplication,
          let (id, channel) = channelEndpoint(of: endpoint)
    else { throw NMOSConnectionError.notFound }

    let parameters = staged.transportParameters.first ?? [:]
    let device = parameters[Self.deviceName]?.nonEmptyString
    let name = parameters[Self.channelName]?.nonEmptyString
    do {
      if staged.masterEnable {
        guard let device, let name else {
          throw NMOSConnectionError.invalid("Subscribing needs both `device_name` and `channel_name`")
        }
        var data = (try? channel.adaptationData.decode(DanteChannelEndpointAdaptationData.self))
          ?? DanteChannelEndpointAdaptationData()
        data.remoteAddress = DanteChannelAddress(device: device, channel: name)
        var subscription = channel
        subscription.adaptationData = try data.blob
        try await application.setChannelEndpoint(
          id: id, channelEndpoint: subscription, from: NMOSConnectionController.shared
        )
      } else {
        try await application.clearChannelEndpoint(id: id, from: NMOSConnectionController.shared)
      }
    } catch {
      throw NMOSConnectionError(error)
    }
    await settle(endpoint, on: staged.masterEnable ? DanteChannelAddress(device: device ?? "", channel: name ?? "") : .init())
  }

  /// The device reports a subscription in its own time; wait for it to show, so that
  /// what is read back after an activation is the result of that activation.
  private func settle(_ endpoint: NMOSOcaEndpoint, on address: DanteChannelAddress) async {
    guard !isSettled(endpoint, on: address) else { return }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.observe(endpoint, until: address) }
      group.addTask { try? await Task.sleep(for: Self.settleTime) }
      await group.next()
      group.cancelAll()
    }
  }

  private func isSettled(_ endpoint: NMOSOcaEndpoint, on address: DanteChannelAddress) -> Bool {
    remoteAddress(of: channelEndpoint(of: endpoint)?.channel) == address
  }

  /// Returns once the channel endpoints show the address, or the application is gone.
  private func observe(_ endpoint: NMOSOcaEndpoint, until address: DanteChannelAddress) async {
    do {
      for try await id in endpoint.application.propertyChanges where id == Self.channelEndpointsID {
        if isSettled(endpoint, on: address) { return }
      }
    } catch {}
  }
}
