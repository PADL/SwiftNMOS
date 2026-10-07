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

/// The `messageType` of an IS-12 protocol message.
enum NcMessageType: Int64, Sendable {
  case command = 0
  case commandResponse = 1
  case notification = 2
  case subscription = 3
  case subscriptionResponse = 4
  case error = 5
}

/// One command of a Command message, under its handle. A command whose handle can be
/// read but whose oid, method or arguments cannot is still answered, with the reason.
struct NcHandledCommand: Sendable, Equatable {
  let handle: Int64
  let command: Result<NcCommand, NcProtocolError>
}

/// What a controller can send.
enum NcIncomingMessage: Sendable, Equatable {
  case commands([NcHandledCommand])
  case subscription([NcOid])
}

/// A message, or part of one, that cannot be acted on. As an Error message it answers
/// what has no handle to answer under; as a command's error it becomes its result.
struct NcProtocolError: Error, Sendable, Equatable {
  let status: NcMethodStatus
  let message: String

  init(_ message: String, status: NcMethodStatus = .badCommandFormat) {
    self.status = status
    self.message = message
  }
}

/// Reads and writes IS-12 messages as the JSON the schemas describe.
enum NcProtocolCodec {
  /// Handles pair a response with its command and are confined to 16 bits.
  static let handles: ClosedRange<Int64> = 1...65535

  static func parse(_ data: Data) throws(NcProtocolError) -> NcIncomingMessage {
    guard let json = try? NMOSJSONValue(data: data), let message = json.objectValue else {
      throw NcProtocolError("The message is not a JSON object")
    }
    guard let rawType = message["messageType"]?.integerValue,
          let type = NcMessageType(rawValue: rawType)
    else {
      throw NcProtocolError("The message has no valid messageType")
    }
    switch type {
    case .command:
      guard let commands = message["commands"]?.arrayValue else {
        throw NcProtocolError("A Command message needs a commands array")
      }
      return try .commands(commands.map(command))
    case .subscription:
      guard let subscriptions = message["subscriptions"]?.arrayValue else {
        throw NcProtocolError("A Subscription message needs a subscriptions array")
      }
      return try .subscription(subscriptions.map { subscription throws(NcProtocolError) in
        guard let oid = subscription.integerValue.flatMap(NcOid.init(exactly:)) else {
          throw NcProtocolError("A subscription is not an object ID")
        }
        return oid
      })
    case .commandResponse, .notification, .subscriptionResponse, .error:
      throw NcProtocolError("Message type \(rawType) is sent by a device, not to one")
    }
  }

  private static func command(_ json: NMOSJSONValue) throws(NcProtocolError) -> NcHandledCommand {
    // without a handle there is nothing to answer under, so the whole message fails
    guard let handle = json["handle"]?.integerValue, handles.contains(handle) else {
      throw NcProtocolError("A command needs an integer handle from 1 to 65535")
    }
    return NcHandledCommand(handle: handle, command: Result { () throws(NcProtocolError) in
      guard let oid = json["oid"]?.integerValue.flatMap(NcOid.init(exactly:)) else {
        throw NcProtocolError("The command has no valid oid")
      }
      guard let methodID = json["methodId"].flatMap(NcElementID.init(json:)) else {
        throw NcProtocolError("The command has no valid methodId")
      }
      let arguments = json["arguments"] ?? .object([:])
      guard arguments.isNull || arguments.objectValue != nil else {
        throw NcProtocolError("The command's arguments are not an object")
      }
      return NcCommand(oid: oid, methodID: methodID, arguments: arguments.objectValue ?? [:])
    })
  }

  /// A method result as its JSON object; a value of `.null` is written, an absent one
  /// is left out, which is the difference between a null value and no value.
  static func json(_ result: NcMethodResult) -> NMOSJSONValue {
    var object = result.fields ?? [:]
    object["status"] = .integer(Int64(result.status.rawValue))
    if let value = result.value {
      object["value"] = value
    }
    if let errorMessage = result.errorMessage {
      object["errorMessage"] = .string(errorMessage)
    }
    return .object(object)
  }

  static func commandResponse(_ responses: [(handle: Int64, result: NcMethodResult)]) -> NMOSJSONValue {
    [
      "messageType": .integer(NcMessageType.commandResponse.rawValue),
      "responses": .array(responses.map {
        ["handle": .integer($0.handle), "result": json($0.result)]
      }),
    ]
  }

  static func notification(_ notifications: [NcNotification]) -> NMOSJSONValue {
    [
      "messageType": .integer(NcMessageType.notification.rawValue),
      "notifications": .array(notifications.map {
        ["oid": .integer(Int64($0.oid)), "eventId": $0.eventID.json, "eventData": $0.eventData]
      }),
    ]
  }

  static func subscriptionResponse(_ oids: [NcOid]) -> NMOSJSONValue {
    [
      "messageType": .integer(NcMessageType.subscriptionResponse.rawValue),
      "subscriptions": .array(oids.map { .integer(Int64($0)) }),
    ]
  }

  static func error(_ error: NcProtocolError) -> NMOSJSONValue {
    [
      "messageType": .integer(NcMessageType.error.rawValue),
      "status": .integer(Int64(error.status.rawValue)),
      "errorMessage": .string(error.message),
    ]
  }
}
