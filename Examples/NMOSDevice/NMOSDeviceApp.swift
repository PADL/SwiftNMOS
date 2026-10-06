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
import Logging
import NMOS
import NMOSOCABridge
import SwiftOCA
import SwiftOCADevice
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An AES70 device with mock AES67 and Dante transports, served as an NMOS node: IS-04
/// (registration, or peer-to-peer), IS-05 for both transports and IS-12. OCP.1 and
/// OCP.2 share the HTTP port with the NMOS APIs, as WebSocket subprotocols, and OCP.1
/// is also served over TCP.
///
///     NMOSDevice [--port 8080] [--oca-port 65000] [--registry URL | --peer-to-peer]
///                [--receivers 4] [--senders 4]
@main
enum NMOSDeviceApp {
  struct Options {
    var port: UInt16 = 8080
    var ocaPort: UInt16 = 65000
    var registryURL: URL?
    var peerToPeer = false
    var receivers = 4
    var senders = 4

    init(_ arguments: [String]) throws {
      var arguments = arguments.dropFirst().makeIterator()
      func value(_ option: String) throws -> String {
        guard let value = arguments.next() else { throw Usage("\(option) needs a value") }
        return value
      }
      while let argument = arguments.next() {
        switch argument {
        case "--port":
          guard let port = UInt16(try value(argument)) else { throw Usage("--port needs a port number") }
          self.port = port
        case "--oca-port":
          guard let port = UInt16(try value(argument)) else { throw Usage("--oca-port needs a port number") }
          ocaPort = port
        case "--registry":
          guard let url = URL(string: try value(argument)) else { throw Usage("--registry needs a URL") }
          registryURL = url
        case "--peer-to-peer":
          peerToPeer = true
        case "--receivers":
          guard let count = Int(try value(argument)), count >= 0 else { throw Usage("--receivers needs a count") }
          receivers = count
        case "--senders":
          guard let count = Int(try value(argument)), count >= 0 else { throw Usage("--senders needs a count") }
          senders = count
        default:
          throw Usage("unknown option \(argument)")
        }
      }
    }
  }

  struct Usage: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  static func main() async throws {
    let options: Options
    do {
      options = try Options(CommandLine.arguments)
    } catch {
      print("NMOSDevice: \(error)")
      print("usage: NMOSDevice [--port 8080] [--oca-port 65000] [--registry URL | --peer-to-peer]")
      print("                  [--receivers N] [--senders N]")
      exit(2)
    }
    let logger = Logger(label: "com.padl.NMOSDevice")
    guard let interface = HostInterface.all().first else {
      print("NMOSDevice: no network interface with an IPv4 address")
      exit(1)
    }
    try await makeDevice(on: interface, options: options)
    try await serve(on: interface, options: options, logger: logger)
  }

  /// The device's objects: a network interface standing for the host's, and the two
  /// transport applications on it.
  @OcaDevice
  private static func makeDevice(on host: HostInterface, options: Options) async throws {
    let device = OcaDevice.shared
    try await device.initializeDefaultObjects()
    // a Dante transmitter is subscribed to by device name, which allows no dots
    let name = String(ProcessInfo.processInfo.hostName.prefix { $0 != "." }.prefix(31))
    let deviceManager = await device.deviceManager
    deviceManager?.deviceName = name.isEmpty ? "NMOSDevice" : name

    let networkManager = try await SwiftOCADevice.OcaNetworkManager(deviceDelegate: device)
    let interface = try await SwiftOCADevice.OcaNetworkInterface(role: "Interface", deviceDelegate: device)
    interface.systemIOInterfaceName = host.name
    interface.currentAdaptationData = try OcaIP4NetworkSettings(
      addressAndPrefix: "\(host.address)/\(host.prefixLength)", autoconfigMode: .none, dhcpServerAddress: "",
      defaultGatewayAddress: "", additionalGateways: [], dnsServerAddresses: [], additionalParameters: ""
    ).blob
    let aes67 = try await MockAes67Application.make(
      receivers: options.receivers, senders: options.senders, address: host.address,
      interface: interface, device: device
    )
    let dante = try await MockDanteApplication.make(
      receivers: options.receivers, senders: options.senders, device: device
    )
    networkManager.networkInterfaces = [interface]
    networkManager.networkApplications = [aes67, dante]
  }

  /// Every IPv4 address on `port`.
  private static func anyAddress(port: UInt16) -> Data {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    return withUnsafeBytes(of: address) { Data($0) }
  }

  /// Serves OCA and the NMOS APIs until the process is stopped.
  private static func serve(on host: HostInterface, options: Options, logger: Logger) async throws {
    let endpoint = try await OcaWSDeviceEndpoint(
      address: anyAddress(port: options.port),
      controlProtocols: [.ocp1, .ocp2]
    )
    let tcpEndpoint = try await OcaTCPDeviceEndpoint(address: anyAddress(port: options.ocaPort))

    let configuration = NMOSNodeConfiguration(registryURL: options.registryURL)
    let store = NMOSResourceStore()
    let port = Int(options.port)
    // the bridge is made first, so the connection provider and device model take its IDs
    let bridge = NMOSOcaBridge(
      store: store,
      controls: NMOSNode.controls(connectionAPI: true, deviceModel: true, configuration: configuration),
      logger: logger
    ) {
      NMOSOcaHost(
        seed: host.macAddress,
        hostname: ProcessInfo.processInfo.hostName,
        endpoints: [.init(host: host.address, port: port)],
        interfaces: [.init(name: host.name, chassisID: nil, portID: host.macAddress)]
      )
    }
    let node = NMOSNode(
      configuration: configuration,
      store: store,
      connectionProvider: NMOSOcaConnectionProvider(logger: logger) { await bridge.ids },
      deviceModel: NMOSOcaDeviceModel(logger: logger) { await bridge.ids },
      discovery: NMOSOcaServiceDiscovery(),
      // a node operating peer-to-peer has no use for a registry
      httpClient: options.peerToPeer ? nil : NMOSFlyingFoxHTTPClient(timeout: configuration.heartbeatInterval),
      logger: logger
    )
    await node.attach(to: endpoint)
    logger.info("serving OCA and NMOS on http://\(host.address):\(port)/x-nmos/, OCP.1 on port \(options.ocaPort)")

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await endpoint.run() }
      group.addTask { try await tcpEndpoint.run() }
      group.addTask { try await node.run() }
      group.addTask { try await bridge.run() }
      try await group.next()
      group.cancelAll()
    }
  }
}
