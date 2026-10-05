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

import FlyingFox
import Foundation
import Logging

/// A control API the node serves for its device, as IS-04 lists them in the device's
/// `controls`: the Connection API, the control protocol, or one of the host's own.
public struct NMOSControl: Sendable, Hashable {
  /// The control type URN with its version, such as `urn:x-nmos:control:sr-ctrl/v1.1`.
  public var type: String
  /// Where it is served, relative to `/x-nmos/`, such as `connection/v1.1/`.
  public var path: String
  /// Whether it is reached by WebSocket rather than plain HTTP.
  public var isWebSocket: Bool

  public init(type: String, path: String, isWebSocket: Bool = false) {
    self.type = type
    self.path = path
    self.isWebSocket = isWebSocket
  }

  /// The control as a device lists it, served from `endpoint`.
  public func deviceControl(at endpoint: NMOSNodeResource.Endpoint) -> NMOSDeviceResource.Control {
    let secure = endpoint.protocol == "https"
    let scheme = isWebSocket ? (secure ? "wss" : "ws") : endpoint.protocol
    return .init(
      href: "\(scheme)://\(endpoint.authority)/\(NMOSRouter.root)/\(path)",
      type: type,
      authorization: endpoint.authorization
    )
  }
}

public extension NMOSNodeResource.Endpoint {
  /// Host and port as a URL writes them, an IPv6 address in brackets.
  var authority: String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }

  /// The root of the HTTP server at this endpoint, without a trailing slash.
  var baseURL: String { "\(`protocol`)://\(authority)" }
}

/// How the node finds a registry and announces itself.
public struct NMOSNodeConfiguration: Sendable {
  /// A Registration API to use instead of discovering one, such as `http://registry:8010`.
  public var registryURL: URL?
  /// Whether to advertise the Node API by mDNS while no registry is in use.
  public var peerToPeer: Bool
  public var heartbeatInterval: Duration
  /// How long to browse for a Registration API before concluding there is none and
  /// operating peer-to-peer. DNS-SD cannot say that a service does not exist, only not
  /// answer; browsing goes on afterwards, and a registry found later is used.
  public var registryDiscoveryTimeout: Duration
  /// The wait before trying again when no Registration API answers: the first wait,
  /// doubled each time up to the last.
  public var registrationBackoff: ClosedRange<Duration>
  /// Controls of the host's own, listed after those of the APIs the node serves.
  public var controls: [NMOSControl]

  public init(
    registryURL: URL? = nil,
    peerToPeer: Bool = true,
    heartbeatInterval: Duration = .seconds(5),
    registryDiscoveryTimeout: Duration = .seconds(3),
    registrationBackoff: ClosedRange<Duration> = .seconds(1)...(.seconds(30)),
    controls: [NMOSControl] = []
  ) {
    self.registryURL = registryURL
    self.peerToPeer = peerToPeer
    self.heartbeatInterval = heartbeatInterval
    self.registryDiscoveryTimeout = registryDiscoveryTimeout
    self.registrationBackoff = registrationBackoff
    self.controls = controls
  }
}

/// An NMOS node: the APIs it serves and the background work behind them. The host
/// describes itself by writing resources to `store`, and may supply a connection
/// provider (IS-05) and a device model (IS-12); each API is served only if it can be.
public final class NMOSNode: Sendable {
  public let configuration: NMOSNodeConfiguration
  public let store: NMOSResourceStore
  public let router: NMOSRouter
  public let connectionProvider: (any NMOSConnectionProvider)?
  public let deviceModel: (any NcDeviceModel)?
  /// The Connection API, which exists if there is a connection provider for it to serve.
  public let connectionAPI: NMOSConnectionAPI?
  public let discovery: (any NMOSServiceDiscovery)?
  public let httpClient: (any NMOSHTTPClient)?
  public let logger: Logger

  public init(
    configuration: NMOSNodeConfiguration = .init(),
    store: NMOSResourceStore = .init(),
    connectionProvider: (any NMOSConnectionProvider)? = nil,
    deviceModel: (any NcDeviceModel)? = nil,
    discovery: (any NMOSServiceDiscovery)? = nil,
    httpClient: (any NMOSHTTPClient)? = nil,
    logger: Logger = Logger(label: "com.padl.NMOS")
  ) {
    self.configuration = configuration
    self.store = store
    self.connectionProvider = connectionProvider
    self.deviceModel = deviceModel
    self.discovery = discovery
    self.httpClient = httpClient
    self.logger = logger
    router = NMOSRouter(logger: logger)
    connectionAPI = connectionProvider.map { NMOSConnectionAPI(provider: $0, store: store, logger: logger) }
  }

  /// Serves the node's APIs from `registrar`, before any catch-all route of the host's
  /// is appended to it. A node whose host listens in several places is attached to each.
  public func attach(to registrar: some NMOSRouteRegistrar) async {
    // the APIs' routes belong to the router, which every registrar shares
    if await router.beginRegistering() {
      await NMOSNodeAPI.register(on: router, store: store)
      await connectionAPI?.register(on: router)
      if let deviceModel {
        await NcControlProtocol.register(on: router, model: deviceModel, logger: logger)
      }
    }
    await router.attach(to: registrar)
  }

  /// The controls a device of a node with these APIs lists: one for each control API that
  /// is served, then the host's own. A host needs them before the node exists, to describe
  /// the device the node is made with.
  public static func controls(
    connectionAPI: Bool,
    deviceModel: Bool,
    configuration: NMOSNodeConfiguration
  ) -> [NMOSControl] {
    // the newest version first, for controllers that take the first Connection API listed
    let connection = !connectionAPI ? [] : NMOSConnectionAPI.versions.reversed().map {
      NMOSControl(type: NMOSConnectionAPI.control($0).type, path: "connection/\($0)/")
    }
    let control = !deviceModel ? [] : [
      NMOSControl(type: NcControlProtocol.controlType, path: NcControlProtocol.path, isWebSocket: true),
    ]
    return connection + control + configuration.controls
  }

  /// Runs the node's background work until the task is cancelled: registration and
  /// heartbeats with a Registration API, or peer-to-peer advertisement without one.
  public func run() async throws {
    let registration = NMOSNodeRegistration(
      configuration: configuration, store: store, discovery: discovery, httpClient: httpClient,
      logger: logger
    )
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await registration.run() }
      if let connectionAPI {
        group.addTask { await connectionAPI.run() }
      }
    }
    try Task.checkCancellation()
  }
}
