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
import Synchronization

/// A device model of objects that are nothing but their properties, answering
/// `NcObject.Get` (1m1) and `NcObject.Set` (1m2), for testing the IS-12 engine.
final class FixtureDeviceModel: NcDeviceModel {
  static let get = NcElementID(level: 1, index: 1)
  static let set = NcElementID(level: 1, index: 2)

  private let objects = Mutex([NcOid: [NcElementID: NMOSJSONValue]]())
  private let listeners = Mutex([NcSession: AsyncStream<NcNotification>.Continuation]())
  /// The sessions the engine has said are over, in the order it said so.
  let ended = Mutex([NcSession]())

  init(objects: [NcOid: [NcElementID: NMOSJSONValue]] = [:]) {
    self.objects.withLock { $0 = objects }
  }

  func value(oid: NcOid, property: NcElementID) -> NMOSJSONValue? {
    objects.withLock { $0[oid]?[property] }
  }

  func handleCommand(_ command: NcCommand, session: NcSession) async -> NcMethodResult {
    let (oid, methodID, arguments) = (command.oid, command.methodID, command.arguments)
    guard let properties = objects.withLock({ $0[oid] }) else {
      return .error(.badOid, "no object \(oid)")
    }
    guard let property = try? arguments["id"]?.decode(NcElementID.self) else {
      return .error(.parameterError, "missing or malformed property id")
    }
    guard properties[property] != nil else {
      return .error(.propertyNotImplemented, "no property \(property)")
    }
    switch methodID {
    case Self.get:
      return NcMethodResult(value: properties[property])
    case Self.set:
      guard let value = arguments["value"] else { return .error(.parameterError, "missing value") }
      objects.withLock { $0[oid]?[property] = value }
      let eventData: NMOSJSONValue = [
        "propertyId": ["level": .integer(Int64(property.level)), "index": .integer(Int64(property.index))],
        "changeType": 0,
        "value": value,
        "sequenceItemIndex": .null,
      ]
      let notification = NcNotification(oid: oid, eventData: eventData)
      for listener in listeners.withLock({ Array($0.values) }) { listener.yield(notification) }
      return NcMethodResult()
    default:
      return .error(.methodNotImplemented, "no method \(methodID)")
    }
  }

  func subscribable(_ oids: [NcOid], session: NcSession) async -> [NcOid] {
    objects.withLock { objects in oids.filter { objects[$0] != nil } }
  }

  /// Every session is sent every event; the engine keeps those it subscribed to.
  func notifications(for session: NcSession) -> AsyncStream<NcNotification> {
    let (stream, continuation) = AsyncStream<NcNotification>.makeStream()
    listeners.withLock { $0[session] = continuation }
    return stream
  }

  func sessionEnded(_ session: NcSession) async {
    listeners.withLock { $0.removeValue(forKey: session) }?.finish()
    ended.withLock { $0.append(session) }
  }
}
