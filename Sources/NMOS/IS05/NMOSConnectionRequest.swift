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

/// How staged settings become active (IS-05 `activation` `mode`).
public enum NMOSActivationMode: String, Sendable, Hashable {
  case immediate = "activate_immediate"
  case scheduledAbsolute = "activate_scheduled_absolute"
  case scheduledRelative = "activate_scheduled_relative"

  var isScheduled: Bool { self != .immediate }
}

/// The `activation` object of a staged or active resource. All three members are null
/// when no activation has been requested.
struct NMOSActivation: Sendable, Hashable {
  var mode: NMOSActivationMode?
  /// An absolute TAI time, or for a relative activation the offset that was asked for.
  var requestedTime: NMOSTimestamp?
  /// When the settings became, or will become, active.
  var activationTime: NMOSTimestamp?

  static let none = NMOSActivation()

  var json: NMOSJSONValue {
    [
      "mode": mode.map { .string($0.rawValue) } ?? .null,
      "requested_time": requestedTime.map { .string($0.description) } ?? .null,
      "activation_time": activationTime.map { .string($0.description) } ?? .null,
    ]
  }
}

/// A `PATCH` to `/staged`, checked against the stage schema. Members the request left
/// out are nil and leave what is staged unchanged.
struct NMOSStageRequest: Sendable {
  var masterEnable: Bool?
  /// The outer optional is whether the request named a peer; the inner is null.
  var peerID: NMOSID??
  var transportParameters: [NMOSTransportParameters]?
  var transportFile: NMOSTransportFile?
  /// The outer optional is whether the request had an `activation` at all.
  var activation: NMOSActivation?

  init(_ json: NMOSJSONValue, kind: NMOSResourceKind) throws {
    guard let object = json.objectValue else {
      throw NMOSHTTPError.badRequest("The request body must be a JSON object")
    }
    let peerKey = kind == .sender ? "receiver_id" : "sender_id"
    for (key, value) in object {
      switch key {
      case "master_enable":
        guard let enable = value.boolValue else {
          throw NMOSHTTPError.badRequest("`master_enable` must be a boolean")
        }
        masterEnable = enable
      case peerKey:
        peerID = try .some(Self.peer(value, key: peerKey))
      case "activation":
        activation = try Self.activation(value)
      case "transport_params":
        transportParameters = try Self.legs(value)
      case "transport_file" where kind == .receiver:
        transportFile = try Self.transportFile(value)
      default:
        throw NMOSHTTPError.badRequest("Un-recognised parameter '\(key)'")
      }
    }
  }

  private static func peer(_ value: NMOSJSONValue, key: String) throws -> NMOSID? {
    if value.isNull { return nil }
    // the schema admits only the lower-case spelling
    guard let string = value.stringValue, string == string.lowercased(), let id = NMOSID(string) else {
      throw NMOSHTTPError.badRequest("`\(key)` must be a UUID or null")
    }
    return id
  }

  private static func activation(_ value: NMOSJSONValue) throws -> NMOSActivation {
    guard let object = value.objectValue, let mode = object["mode"],
          object.keys.allSatisfy({ $0 == "mode" || $0 == "requested_time" })
    else {
      throw NMOSHTTPError.badRequest("`activation` must be an object with a `mode`")
    }
    var activation = NMOSActivation()
    if !mode.isNull {
      guard let parsed = mode.stringValue.flatMap(NMOSActivationMode.init(rawValue:)) else {
        throw NMOSHTTPError.badRequest("`mode` is not an activation mode")
      }
      activation.mode = parsed
    }
    if let time = object["requested_time"], !time.isNull {
      guard let parsed = time.stringValue.flatMap(NMOSTimestamp.init) else {
        throw NMOSHTTPError.badRequest("`requested_time` must be a TAI timestamp, <seconds>:<nanoseconds>")
      }
      activation.requestedTime = parsed
    }
    if activation.mode?.isScheduled == true, activation.requestedTime == nil {
      throw NMOSHTTPError.badRequest("A scheduled activation needs a `requested_time`")
    }
    return activation
  }

  private static func legs(_ value: NMOSJSONValue) throws -> [NMOSTransportParameters] {
    guard let array = value.arrayValue else {
      throw NMOSHTTPError.badRequest("`transport_params` must be an array")
    }
    return try array.map { leg in
      guard let parameters = leg.objectValue else {
        throw NMOSHTTPError.badRequest("Each element of `transport_params` must be an object")
      }
      for (name, value) in parameters {
        switch value {
        case .array, .object:
          throw NMOSHTTPError.badRequest("`\(name)` must be a string, number, boolean or null")
        default:
          break
        }
      }
      return parameters
    }
  }

  private static func transportFile(_ value: NMOSJSONValue) throws -> NMOSTransportFile {
    func member(_ name: String, of object: [String: NMOSJSONValue]) throws -> String? {
      guard let value = object[name] else {
        throw NMOSHTTPError.badRequest("`transport_file` must have `data` and `type`")
      }
      if value.isNull { return nil }
      guard let string = value.stringValue else {
        throw NMOSHTTPError.badRequest("`transport_file` `\(name)` must be a string or null")
      }
      return string
    }
    guard let object = value.objectValue, object.keys.allSatisfy({ $0 == "data" || $0 == "type" }) else {
      throw NMOSHTTPError.badRequest("`transport_file` must be an object with `data` and `type`")
    }
    return try NMOSTransportFile(data: member("data", of: object), type: member("type", of: object))
  }
}

extension NMOSConnectionState {
  /// The staged or active resource as the response schemas have it.
  func json(_ kind: NMOSResourceKind, activation: NMOSActivation) -> NMOSJSONValue {
    var object: [String: NMOSJSONValue] = [
      kind == .sender ? "receiver_id" : "sender_id": peerID.map { .string($0.description) } ?? .null,
      "master_enable": .bool(masterEnable),
      "activation": activation.json,
      "transport_params": .array(transportParameters.map { .object($0) }),
    ]
    if kind == .receiver {
      object["transport_file"] = [
        "data": transportFile?.data.map { .string($0) } ?? .null,
        "type": transportFile?.type.map { .string($0) } ?? .null,
      ]
    }
    return .object(object)
  }
}
