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

/// The six resource types of the IS-04 data model, named as the Registration API names them.
public enum NMOSResourceKind: String, Sendable, Codable, CaseIterable, Hashable {
  case node, device, source, flow, sender, receiver

  /// The Node API collection holding resources of this kind; the node itself is `/self`.
  public var collection: String { self == .node ? "self" : rawValue + "s" }

  /// Registration order: a resource is registered after the resource it refers to.
  public static let registrationOrder: [Self] = [.node, .device, .source, .flow, .sender, .receiver]
}

/// An optional value the schemas require to be present, written as `null` rather than
/// omitted when there is none.
@propertyWrapper
public struct NMOSNullable<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
  public var wrappedValue: Value?

  public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
  }
}

public extension KeyedDecodingContainer {
  /// Lets a missing key decode as nil, so reading is lenient where writing is strict.
  func decode<T>(_ type: NMOSNullable<T>.Type, forKey key: Key) throws -> NMOSNullable<T> {
    try decodeIfPresent(type, forKey: key) ?? NMOSNullable(wrappedValue: nil)
  }
}

/// What every resource carries (IS-04 `resource_core`).
public protocol NMOSResourceRepresentable: Codable, Sendable, Hashable {
  static var kind: NMOSResourceKind { get }
  var id: NMOSID { get }
  /// Set by the resource store whenever the resource's content changes.
  var version: NMOSTimestamp { get set }
  var label: String { get }
  var description: String { get }
  var tags: [String: [String]] { get }
}

/// A fraction, for sample and grain rates.
public struct NMOSRational: Codable, Sendable, Hashable {
  public let numerator: Int
  public let denominator: Int

  public init(numerator: Int, denominator: Int = 1) {
    self.numerator = numerator
    self.denominator = denominator
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    numerator = try container.decode(Int.self, forKey: .numerator)
    denominator = try container.decodeIfPresent(Int.self, forKey: .denominator) ?? 1
  }
}

public enum NMOSFormat {
  public static let audio = "urn:x-nmos:format:audio"
}

// MARK: - Node

/// A clock a node's sources can be timed from (IS-04 `clock_internal`, `clock_ptp`).
public enum NMOSClock: Sendable, Hashable {
  case `internal`(name: String)
  /// `gmid` is the grandmaster identity as eight lower-case hyphen-separated octets.
  case ptp(name: String, traceable: Bool, gmid: String, locked: Bool)

  public var name: String {
    switch self {
    case let .internal(name): name
    case let .ptp(name, _, _, _): name
    }
  }
}

extension NMOSClock: Codable {
  private enum CodingKeys: String, CodingKey {
    case name, traceable, version, gmid, locked
    case refType = "ref_type"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(String.self, forKey: .name)
    switch try container.decode(String.self, forKey: .refType) {
    case "internal":
      self = .internal(name: name)
    case "ptp":
      self = try .ptp(
        name: name,
        traceable: container.decode(Bool.self, forKey: .traceable),
        gmid: container.decode(String.self, forKey: .gmid),
        locked: container.decode(Bool.self, forKey: .locked)
      )
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .refType, in: container, debugDescription: "unknown clock ref_type \(other)"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    switch self {
    case .internal:
      try container.encode("internal", forKey: .refType)
    case let .ptp(_, traceable, gmid, locked):
      try container.encode("ptp", forKey: .refType)
      try container.encode(traceable, forKey: .traceable)
      try container.encode("IEEE1588-2008", forKey: .version)
      try container.encode(gmid, forKey: .gmid)
      try container.encode(locked, forKey: .locked)
    }
  }
}

public struct NMOSNodeResource: NMOSResourceRepresentable {
  public static let kind = NMOSResourceKind.node

  public struct Endpoint: Codable, Sendable, Hashable {
    public let host: String
    public let port: Int
    public var `protocol`: String
    public let authorization: Bool?

    public init(host: String, port: Int, protocol: String = "http", authorization: Bool? = nil) {
      self.host = host
      self.port = port
      self.protocol = `protocol`
      self.authorization = authorization
    }
  }

  public struct API: Codable, Sendable, Hashable {
    public let versions: [NMOSAPIVersion]
    public let endpoints: [Endpoint]

    public init(versions: [NMOSAPIVersion], endpoints: [Endpoint]) {
      self.versions = versions
      self.endpoints = endpoints
    }
  }

  public struct Service: Codable, Sendable, Hashable {
    public let href: String
    public let type: String
    public let authorization: Bool?

    public init(href: String, type: String, authorization: Bool? = nil) {
      self.href = href
      self.type = type
      self.authorization = authorization
    }
  }

  /// A network interface. `portID` is its MAC address as six lower-case hyphen-separated
  /// octets; `chassisID` is the MAC address or other ID of the chassis, when known.
  public struct Interface: Codable, Sendable, Hashable {
    public struct AttachedNetworkDevice: Codable, Sendable, Hashable {
      public let chassisID: String
      public let portID: String

      public init(chassisID: String, portID: String) {
        self.chassisID = chassisID
        self.portID = portID
      }

      private enum CodingKeys: String, CodingKey {
        case chassisID = "chassis_id"
        case portID = "port_id"
      }
    }

    public let name: String
    @NMOSNullable public var chassisID: String?
    public let portID: String
    public let attachedNetworkDevice: AttachedNetworkDevice?

    public init(
      name: String,
      chassisID: String?,
      portID: String,
      attachedNetworkDevice: AttachedNetworkDevice? = nil
    ) {
      self.name = name
      self.chassisID = chassisID
      self.portID = portID
      self.attachedNetworkDevice = attachedNetworkDevice
    }

    private enum CodingKeys: String, CodingKey {
      case name
      case chassisID = "chassis_id"
      case portID = "port_id"
      case attachedNetworkDevice = "attached_network_device"
    }
  }

  public let id: NMOSID
  public var version: NMOSTimestamp
  public var label: String
  public var description: String
  public let tags: [String: [String]]
  /// Deprecated by IS-04 in favour of `api`, but still required.
  public let href: String
  public let hostname: String?
  public let api: API
  public let caps: [String: NMOSJSONValue]
  public let services: [Service]
  public var clocks: [NMOSClock]
  public let interfaces: [Interface]

  public init(
    id: NMOSID,
    version: NMOSTimestamp = .init(seconds: 0),
    label: String,
    description: String,
    tags: [String: [String]] = [:],
    href: String,
    hostname: String? = nil,
    api: API,
    caps: [String: NMOSJSONValue] = [:],
    services: [Service] = [],
    clocks: [NMOSClock] = [],
    interfaces: [Interface] = []
  ) {
    self.id = id
    self.version = version
    self.label = label
    self.description = description
    self.tags = tags
    self.href = href
    self.hostname = hostname
    self.api = api
    self.caps = caps
    self.services = services
    self.clocks = clocks
    self.interfaces = interfaces
  }
}

// MARK: - Device

public struct NMOSDeviceResource: NMOSResourceRepresentable {
  public static let kind = NMOSResourceKind.device

  public static let genericType = "urn:x-nmos:device:generic"

  /// A control endpoint of the device, such as its Connection API or control protocol.
  public struct Control: Codable, Sendable, Hashable {
    public let href: String
    public let type: String
    public let authorization: Bool?

    public init(href: String, type: String, authorization: Bool? = nil) {
      self.href = href
      self.type = type
      self.authorization = authorization
    }
  }

  public let id: NMOSID
  public var version: NMOSTimestamp
  public var label: String
  public var description: String
  public let tags: [String: [String]]
  public let type: String
  public let nodeID: NMOSID
  /// Deprecated by IS-04 in favour of finding senders and receivers by their `device_id`.
  /// The schema still requires both, so they are published, and left empty.
  public let senders: [NMOSID]
  public let receivers: [NMOSID]
  public let controls: [Control]

  public init(
    id: NMOSID,
    version: NMOSTimestamp = .init(seconds: 0),
    label: String,
    description: String,
    tags: [String: [String]] = [:],
    type: String = NMOSDeviceResource.genericType,
    nodeID: NMOSID,
    senders: [NMOSID] = [],
    receivers: [NMOSID] = [],
    controls: [Control] = []
  ) {
    self.id = id
    self.version = version
    self.label = label
    self.description = description
    self.tags = tags
    self.type = type
    self.nodeID = nodeID
    self.senders = senders
    self.receivers = receivers
    self.controls = controls
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, label, description, tags, type, senders, receivers, controls
    case nodeID = "node_id"
  }
}

// MARK: - Source and flow

/// An audio source (IS-04 `source_audio`).
public struct NMOSSourceResource: NMOSResourceRepresentable {
  public static let kind = NMOSResourceKind.source

  public struct Channel: Codable, Sendable, Hashable {
    public let label: String
    /// A channel symbol from the NMOS audio channel symbol set, such as `L` or `U01`.
    public let symbol: String?

    public init(label: String, symbol: String? = nil) {
      self.label = label
      self.symbol = symbol
    }
  }

  public let id: NMOSID
  public var version: NMOSTimestamp
  public var label: String
  public var description: String
  public let tags: [String: [String]]
  public let caps: [String: NMOSJSONValue]
  public let deviceID: NMOSID
  public let parents: [NMOSID]
  /// The name of the node clock this source is timed from.
  @NMOSNullable public var clockName: String?
  public let format: String
  public let channels: [Channel]

  public init(
    id: NMOSID,
    version: NMOSTimestamp = .init(seconds: 0),
    label: String,
    description: String,
    tags: [String: [String]] = [:],
    caps: [String: NMOSJSONValue] = [:],
    deviceID: NMOSID,
    parents: [NMOSID] = [],
    clockName: String?,
    format: String = NMOSFormat.audio,
    channels: [Channel]
  ) {
    self.id = id
    self.version = version
    self.label = label
    self.description = description
    self.tags = tags
    self.caps = caps
    self.deviceID = deviceID
    self.parents = parents
    self.clockName = clockName
    self.format = format
    self.channels = channels
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, label, description, tags, caps, parents, format, channels
    case deviceID = "device_id"
    case clockName = "clock_name"
  }
}

/// An audio flow (IS-04 `flow_audio_raw`, or `flow_audio_coded` when `bitDepth` is nil).
public struct NMOSFlowResource: NMOSResourceRepresentable {
  public static let kind = NMOSResourceKind.flow

  public let id: NMOSID
  public var version: NMOSTimestamp
  public var label: String
  public var description: String
  public let tags: [String: [String]]
  public let sourceID: NMOSID
  public let deviceID: NMOSID
  public let parents: [NMOSID]
  public let format: String
  public let sampleRate: NMOSRational
  /// Such as `audio/L24`.
  public let mediaType: String
  public let bitDepth: Int?

  public init(
    id: NMOSID,
    version: NMOSTimestamp = .init(seconds: 0),
    label: String,
    description: String,
    tags: [String: [String]] = [:],
    sourceID: NMOSID,
    deviceID: NMOSID,
    parents: [NMOSID] = [],
    format: String = NMOSFormat.audio,
    sampleRate: NMOSRational,
    mediaType: String,
    bitDepth: Int?
  ) {
    self.id = id
    self.version = version
    self.label = label
    self.description = description
    self.tags = tags
    self.sourceID = sourceID
    self.deviceID = deviceID
    self.parents = parents
    self.format = format
    self.sampleRate = sampleRate
    self.mediaType = mediaType
    self.bitDepth = bitDepth
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, label, description, tags, parents, format
    case sourceID = "source_id"
    case deviceID = "device_id"
    case sampleRate = "sample_rate"
    case mediaType = "media_type"
    case bitDepth = "bit_depth"
  }
}

// MARK: - Sender and receiver

public struct NMOSSenderResource: NMOSResourceRepresentable {
  public static let kind = NMOSResourceKind.sender

  public struct Subscription: Codable, Sendable, Hashable {
    /// The receiver a unicast sender is sending to, when it is an NMOS receiver.
    @NMOSNullable public var receiverID: NMOSID?
    public var active: Bool

    public init(receiverID: NMOSID? = nil, active: Bool) {
      self.receiverID = receiverID
      self.active = active
    }

    private enum CodingKeys: String, CodingKey {
      case active
      case receiverID = "receiver_id"
    }
  }

  public let id: NMOSID
  public var version: NMOSTimestamp
  public var label: String
  public var description: String
  public let tags: [String: [String]]
  public let caps: [String: NMOSJSONValue]?
  @NMOSNullable public var flowID: NMOSID?
  public let transport: String
  public let deviceID: NMOSID
  /// Where the transport file (SDP for RTP) can be fetched, when the transport has one.
  @NMOSNullable public var manifestHref: String?
  /// Names of the node interfaces the sender sends from, one per leg.
  public let interfaceBindings: [String]
  public var subscription: Subscription

  public init(
    id: NMOSID,
    version: NMOSTimestamp = .init(seconds: 0),
    label: String,
    description: String,
    tags: [String: [String]] = [:],
    caps: [String: NMOSJSONValue]? = nil,
    flowID: NMOSID?,
    transport: String,
    deviceID: NMOSID,
    manifestHref: String?,
    interfaceBindings: [String],
    subscription: Subscription
  ) {
    self.id = id
    self.version = version
    self.label = label
    self.description = description
    self.tags = tags
    self.caps = caps
    self.flowID = flowID
    self.transport = transport
    self.deviceID = deviceID
    self.manifestHref = manifestHref
    self.interfaceBindings = interfaceBindings
    self.subscription = subscription
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, label, description, tags, caps, transport, subscription
    case flowID = "flow_id"
    case deviceID = "device_id"
    case manifestHref = "manifest_href"
    case interfaceBindings = "interface_bindings"
  }
}

/// An audio receiver (IS-04 `receiver_audio`).
public struct NMOSReceiverResource: NMOSResourceRepresentable {
  public static let kind = NMOSResourceKind.receiver

  public struct Subscription: Codable, Sendable, Hashable {
    /// The sender the receiver is receiving from, when it is an NMOS sender.
    @NMOSNullable public var senderID: NMOSID?
    public var active: Bool

    public init(senderID: NMOSID? = nil, active: Bool) {
      self.senderID = senderID
      self.active = active
    }

    private enum CodingKeys: String, CodingKey {
      case active
      case senderID = "sender_id"
    }
  }

  public struct Capabilities: Codable, Sendable, Hashable {
    /// The media types the receiver can consume, such as `audio/L24`.
    public let mediaTypes: [String]?

    public init(mediaTypes: [String]? = nil) { self.mediaTypes = mediaTypes }

    private enum CodingKeys: String, CodingKey {
      case mediaTypes = "media_types"
    }
  }

  public let id: NMOSID
  public var version: NMOSTimestamp
  public var label: String
  public var description: String
  public let tags: [String: [String]]
  public let deviceID: NMOSID
  public let transport: String
  public let interfaceBindings: [String]
  public var subscription: Subscription
  public let format: String
  public let caps: Capabilities

  public init(
    id: NMOSID,
    version: NMOSTimestamp = .init(seconds: 0),
    label: String,
    description: String,
    tags: [String: [String]] = [:],
    deviceID: NMOSID,
    transport: String,
    interfaceBindings: [String],
    subscription: Subscription,
    format: String = NMOSFormat.audio,
    caps: Capabilities = .init()
  ) {
    self.id = id
    self.version = version
    self.label = label
    self.description = description
    self.tags = tags
    self.deviceID = deviceID
    self.transport = transport
    self.interfaceBindings = interfaceBindings
    self.subscription = subscription
    self.format = format
    self.caps = caps
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, label, description, tags, transport, subscription, format, caps
    case deviceID = "device_id"
    case interfaceBindings = "interface_bindings"
  }
}

// MARK: - Any resource

/// A resource of any kind, as the resource store holds them.
public enum NMOSResource: Sendable, Hashable {
  case node(NMOSNodeResource)
  case device(NMOSDeviceResource)
  case source(NMOSSourceResource)
  case flow(NMOSFlowResource)
  case sender(NMOSSenderResource)
  case receiver(NMOSReceiverResource)

  private var base: any NMOSResourceRepresentable {
    switch self {
    case let .node(resource): resource
    case let .device(resource): resource
    case let .source(resource): resource
    case let .flow(resource): resource
    case let .sender(resource): resource
    case let .receiver(resource): resource
    }
  }

  public var kind: NMOSResourceKind { type(of: base).kind }
  public var id: NMOSID { base.id }

  public var version: NMOSTimestamp {
    get { base.version }
    set {
      switch self {
      case var .node(resource): resource.version = newValue; self = .node(resource)
      case var .device(resource): resource.version = newValue; self = .device(resource)
      case var .source(resource): resource.version = newValue; self = .source(resource)
      case var .flow(resource): resource.version = newValue; self = .flow(resource)
      case var .sender(resource): resource.version = newValue; self = .sender(resource)
      case var .receiver(resource): resource.version = newValue; self = .receiver(resource)
      }
    }
  }
}

extension NMOSResource: Encodable {
  /// Encodes as the resource itself, with no wrapper naming its kind.
  public func encode(to encoder: any Encoder) throws {
    try base.encode(to: encoder)
  }
}
