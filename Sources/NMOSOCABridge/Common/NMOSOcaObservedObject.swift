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
import SwiftOCA
import SwiftOCADevice

/// Properties of OCA objects that some part of the bridge reads, each declared beside the
/// code that reads it. The bridge observes an object for changes to what any part reads.
public struct NMOSOcaObservedProperties: Sendable {
  typealias Getter = @Sendable @OcaDevice (SwiftOCADevice.OcaRoot) -> any Equatable & Sendable

  private struct Entry: Sendable {
    let classID: OcaClassID
    /// Whether an object is of the Swift class, as several may share one class ID.
    let matches: @Sendable (SwiftOCADevice.OcaRoot) -> Bool
    let getters: [OcaPropertyID: Getter]
  }

  private var entries: [Entry]

  public static let empty = NMOSOcaObservedProperties(entries: [])

  /// The properties of `T` that are read, with how each is read.
  public static func of<T: SwiftOCADevice.OcaRoot>(
    _: T.Type,
    _ getters: [OcaPropertyID: @Sendable @OcaDevice (T) -> any Equatable & Sendable]
  ) -> NMOSOcaObservedProperties {
    NMOSOcaObservedProperties(entries: [Entry(
      classID: T.classID,
      matches: { $0 is T },
      getters: getters.mapValues { get in { object in (object as? T).map(get) ?? [String]() } }
    )])
  }

  public static func + (lhs: NMOSOcaObservedProperties, rhs: NMOSOcaObservedProperties) -> NMOSOcaObservedProperties {
    NMOSOcaObservedProperties(entries: lhs.entries + rhs.entries)
  }

  /// What is read of the object, and the highest level of a class declared for it; none
  /// and zero for an object of a class nobody declares.
  func getters(for object: SwiftOCADevice.OcaRoot) -> (getters: [OcaPropertyID: Getter], level: OcaUint16) {
    let matching = entries.filter { $0.matches(object) }
    let getters = matching.reduce(into: [OcaPropertyID: Getter]()) { $0.merge($1.getters) { first, _ in first } }
    // properties above the deepest class declared are a subclass's
    return (getters, matching.map(\.classID.defLevel).max() ?? 0)
  }

  /// The classes declared, and those an object is one of; for tests.
  var classIDs: Set<OcaClassID> { Set(entries.map(\.classID)) }

  func classIDs(of object: SwiftOCADevice.OcaRoot) -> Set<OcaClassID> {
    Set(entries.filter { $0.matches(object) }.map(\.classID))
  }
}

/// An object the bridge describes the device from, observed for changes to what it
/// reads of it and to nothing else. A transport reports counters and status several
/// times a second; neither changes what NMOS is told, and describing the device again
/// for each would keep it busy.
@OcaDevice
final class NMOSOcaObservedObject {
  let object: SwiftOCADevice.OcaRoot
  /// The properties the bridge reads, with how each is read.
  private let getters: [OcaPropertyID: NMOSOcaObservedProperties.Getter]
  /// Properties above this level are a subclass's, which may be read by an adaptation
  /// this knows nothing of, so a change to one counts.
  private let knownLevel: OcaUint16
  private var signalled = Set<OcaPropertyID>()
  /// What each property read held when this was made, until its first signal.
  private var snapshot = [OcaPropertyID: any Equatable & Sendable]()

  /// The values are read here, so a change made after this is not missed: whoever
  /// observes the object describes the device once more after making this.
  init(_ object: SwiftOCADevice.OcaRoot, observing properties: NMOSOcaObservedProperties) {
    self.object = object
    (getters, knownLevel) = properties.getters(for: object)
    for (id, get) in getters { snapshot[id] = get(object) }
  }

  /// Whether a signalled property is one the bridge reads and now holds another value.
  /// A property first signals the value it has; after that, SwiftOCA signals a change only.
  func isChange(_ id: OcaPropertyID) -> Bool {
    guard let get = getters[id] else {
      guard id.defLevel > knownLevel else { return false }
      return !signalled.insert(id).inserted
    }
    guard let previous = snapshot.removeValue(forKey: id) else { return true }
    return !Self.isSame(previous, get(object))
  }

  private static func isSame<T: Equatable>(_ previous: T, _ value: any Equatable) -> Bool {
    (value as? T) == previous
  }

  /// Calls `changed` for each change the bridge would see, until it answers false, when
  /// this returns true, or the object is gone, when it returns false.
  @discardableResult
  func observe(_ changed: @OcaDevice (OcaPropertyID) async -> Bool) async -> Bool {
    do {
      for try await id in object.propertyChanges where isChange(id) {
        guard await changed(id) else { return true }
      }
    } catch {}
    return false
  }

  /// Observes the objects together until `changed` answers false for one or `alongside`
  /// returns, either of which says the set of objects may have changed, or until all are
  /// gone. One that goes is no longer observed; whatever removed it says so itself.
  static func observe(
    _ objects: [NMOSOcaObservedObject],
    alongside: (@Sendable () async -> Void)? = nil,
    _ changed: @escaping @Sendable @OcaDevice (NMOSOcaObservedObject) async -> Bool
  ) async {
    await withTaskGroup(of: Bool.self) { group in
      for object in objects {
        group.addTask { await object.observe { _ in await changed(object) } }
      }
      if let alongside { group.addTask { await alongside(); return true } }
      for await setChanged in group where setChanged { break }
      group.cancelAll()
    }
  }
}
