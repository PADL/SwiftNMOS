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

/// Identifies a property, method or event within a class: the inheritance level of the
/// class that defines it, and its index there (MS-05-02 `NcElementId`).
public struct NcElementID: Codable, Sendable, Hashable, CustomStringConvertible {
  public let level: UInt16
  public let index: UInt16

  public init(level: UInt16, index: UInt16) {
    self.level = level
    self.index = index
  }

  public var description: String { "\(level).\(index)" }

  /// `NcObject.PropertyChanged`, the one event MS-05-02 v1.0 defines.
  public static let propertyChanged = Self(level: 1, index: 1)
}

/// MS-05-02 `NcMethodStatus`; the values follow HTTP status codes.
public enum NcMethodStatus: Int, Codable, Sendable {
  case ok = 200
  case propertyDeprecated = 298
  case methodDeprecated = 299
  case badCommandFormat = 400
  case unauthorized = 401
  case badOid = 404
  case readonly = 405
  case invalidRequest = 406
  case conflict = 409
  case bufferOverflow = 413
  case indexOutOfBounds = 414
  case parameterError = 417
  case locked = 423
  case deviceError = 500
  case methodNotImplemented = 501
  case propertyNotImplemented = 502
  case notReady = 503
  case timeout = 504

  public var isError: Bool { rawValue >= 400 }
}

/// The result of a method: `NcMethodResult` and the types derived from it. A result
/// carries a value when the method returns one, or an error message when it failed.
public struct NcMethodResult: Codable, Sendable, Hashable {
  public let status: NcMethodStatus
  public let value: NMOSJSONValue?
  public let errorMessage: String?
  /// The fields of a derived result type other than `value`, such as the several
  /// results of a non-standard method.
  public let fields: [String: NMOSJSONValue]?

  public init(status: NcMethodStatus = .ok, value: NMOSJSONValue? = nil) {
    self.init(status: status, value: value, errorMessage: nil, fields: nil)
  }

  public init(fields: [String: NMOSJSONValue]) {
    self.init(status: .ok, value: nil, errorMessage: nil, fields: fields)
  }

  private init(status: NcMethodStatus, value: NMOSJSONValue?, errorMessage: String?, fields: [String: NMOSJSONValue]?) {
    self.status = status
    self.value = value
    self.errorMessage = errorMessage
    self.fields = fields
  }

  public static func error(_ status: NcMethodStatus, _ message: String) -> Self {
    Self(status: status, value: nil, errorMessage: message, fields: nil)
  }
}

/// An event from an object, which IS-12 sends to the sessions subscribed to it.
public struct NcNotification: Sendable, Hashable {
  public let oid: NcOid
  public let eventID: NcElementID
  /// For `PropertyChanged`, an `NcPropertyChangedEventData` object.
  public let eventData: NMOSJSONValue

  public init(oid: NcOid, eventID: NcElementID = .propertyChanged, eventData: NMOSJSONValue) {
    self.oid = oid
    self.eventID = eventID
    self.eventData = eventData
  }
}

/// A control session: one connection of the control protocol, and so one controller.
/// A device model is told which session each call is for, so that it can act for that
/// client and no other: with its access, its locks and its subscriptions.
public struct NcSession: Sendable, Hashable, CustomStringConvertible {
  /// Where a session's controller is.
  public enum Peer: Sendable, Hashable {
    case ip(String, port: UInt16)
    /// A socket of this host's file system, which only a local process can reach.
    case local(String)
  }

  public let id: UUID
  /// Nil when the transport cannot say; such a peer is not taken to be local.
  public let peer: Peer?

  public init(id: UUID = UUID(), peer: Peer?) {
    self.id = id
    self.peer = peer
  }

  /// The peer as an endpoint, `address:port`, for logs.
  public var description: String {
    switch peer {
    case let .ip(address, port): address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    case let .local(path): path.isEmpty ? "local" : path
    case nil: "unknown"
    }
  }
}

/// A method of an object, with its arguments, as an IS-12 command carries it. Reading a
/// property is a command too (`NcObject.Get`). `arguments` is keyed by the parameter
/// names of the method's descriptor.
public struct NcCommand: Sendable, Equatable {
  public let oid: NcOid
  public let methodID: NcElementID
  public let arguments: [String: NMOSJSONValue]

  public init(oid: NcOid, methodID: NcElementID, arguments: [String: NMOSJSONValue] = [:]) {
    self.oid = oid
    self.methodID = methodID
    self.arguments = arguments
  }
}

/// The device's MS-05-02 object model, as the IS-12 protocol engine drives it. Every
/// interaction is a method on an object, including reading a property (`NcObject.Get`),
/// so the engine needs no knowledge of the classes behind it.
public protocol NcDeviceModel: Sendable {
  /// Handles a command for a session. Failures are reported in the result, never thrown.
  func handleCommand(_ command: NcCommand, session: NcSession) async -> NcMethodResult

  /// The members of `oids` that exist and that the session can subscribe to.
  func subscribable(_ oids: [NcOid], session: NcSession) async -> [NcOid]

  /// The events the session is to be sent, from now until it ends. A model can send
  /// every object's; the engine passes on those of the objects the session subscribed to.
  func notifications(for session: NcSession) -> AsyncStream<NcNotification>

  /// Tells the model which objects the session is now subscribed to, whenever that
  /// changes, so a model that has to ask for an object's events need not ask for all.
  func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async

  /// The session's connection has closed: nothing more will be asked for it, and what
  /// the model holds for it (subscriptions, locks) can go.
  func sessionEnded(_ session: NcSession) async
}

public extension NcDeviceModel {
  func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {}
  private func sessionEnded(_ session: NcSession) async {}
}
