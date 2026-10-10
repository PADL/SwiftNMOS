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
@_spi(SwiftOCAPrivate)
import SwiftOCA
@_spi(SwiftOCAPrivate)
import SwiftOCADevice
import Synchronization

/// An OCA device as an MS-05-02 device model, for the IS-12 control protocol.
public typealias NMOSOcaDeviceModel = NcObjectModel<NMOSOcaObjectSource>

public extension NcObjectModel where Source == NMOSOcaObjectSource {
  /// `resourceIDs` gives the IDs of the device's IS-04 resources once they are known,
  /// so that objects can point to the resources they stand for. `labels` keeps the user
  /// labels the OCA objects cannot.
  convenience init(
    device: OcaDevice = .shared,
    adaptations: NMOSOcaAdaptations = .standard,
    labels: any NMOSOcaLabelStore = NMOSOcaMemoryLabelStore(),
    logger: Logger = Logger(label: "com.padl.NMOSOCABridge"),
    resourceIDs: @escaping NMOSOcaObjectSource.ResourceIDs = { nil }
  ) {
    self.init(
      source: NMOSOcaObjectSource(
        device: device, adaptations: adaptations, labels: labels, logger: logger, resourceIDs: resourceIDs
      )
    )
  }

  /// Where the class manager is, which is where the bridge makes it.
  var classManagerOid: NcOid { source.classManagerOid }
}

/// The objects of an OCA device, presented as MS-05-02 objects. Properties are read and
/// written by sending the object its own accessor commands, as an OCP.2 controller
/// would, so locks, access checks and whatever the object does on a set all still apply.
///
/// Each control session is a controller of its own to the device, with the session's
/// peer as its identity: what a session may do, lock and hear of is what the device
/// allows a controller at that address, never what it allows the bridge.
@OcaDevice
public final class NMOSOcaObjectSource: NcObjectSource {
  /// An object is known by its OCA object.
  public typealias Object = SwiftOCADevice.OcaRoot
  public typealias ResourceIDs = @Sendable () async -> NMOSOcaResourceIDs?

  /// A control session as the device sees it, and what it has been told so far.
  private struct Session {
    let controller: NMOSOcaControlController
    var subscribed = Set<NcOid>()
    /// What the session's controller holds with the device for each subscribed object.
    var subscriptions = [NcOid: [OcaSubscriptionManagerSubscription]]()
    /// What was last notified of each subscribed object, so a change is notified once.
    var notified = [NcOid: [NcElementID: NMOSJSONValue]]()
  }

  private let device: OcaDevice
  /// The oid the class manager is presented under.
  nonisolated var classManagerOid: NcOid { NMOSOcaControlMapping.oid(of: OcaClassManagerONo) }
  private let adaptations: NMOSOcaAdaptations
  private let classes: NMOSOcaControlClasses
  private let labels: any NMOSOcaLabelStore
  private let logger: Logger
  private let resourceIDs: ResourceIDs

  private var sessions = [NcSession: Session]()
  /// Where the device finds the sessions' controllers.
  let endpoint = NMOSOcaControlEndpoint()
  /// Giving the device the endpoint, which every caller waits for.
  private var registration: Task<Void, Never>?
  /// Each block's members' roles, with the members they were worked out for.
  private var roles = [OcaONo: (members: [OcaONo], roles: [OcaONo: String])]()
  /// Each session's event stream, with an ID that tells it from a later one for the session.
  private nonisolated let listeners = Mutex([NcSession: (id: UUID, continuation: AsyncStream<NcNotification>.Continuation)]())

  nonisolated init(
    device: OcaDevice,
    adaptations: NMOSOcaAdaptations,
    labels: any NMOSOcaLabelStore,
    logger: Logger,
    resourceIDs: @escaping ResourceIDs
  ) {
    self.device = device
    self.adaptations = adaptations
    self.labels = labels
    self.logger = logger
    self.resourceIDs = resourceIDs
    classes = NMOSOcaControlClasses(logger: logger)
    // MS-05-02 has a class manager, which IS-12 presents the device's as; a device that
    // has not created one gets one as the bridge starts
    Task { @OcaDevice [device] in
      guard await device.classManager == nil else { return }
      _ = try? await SwiftOCADevice.OcaClassManager(deviceDelegate: device)
    }
  }

  /// The device holds the endpoint, and through it every subscription of the sessions'
  /// controllers and the bridge's own; they go with it.
  deinit {
    guard registration != nil else { return }
    let device = device, endpoint = endpoint
    Task { @OcaDevice in try? await device.remove(endpoint: endpoint) }
  }

  // MARK: - The tree

  /// The object an oid stands for, looked up in the device as it is now: the tree is
  /// OCA's, and nothing of it is kept here. An object is in the tree if it is the root
  /// block, or its owner is.
  public func identity(of oid: NcOid) async -> Identity? {
    guard let root = await device.rootBlock,
          let object = await device.objects[NMOSOcaControlMapping.objectNumber(of: oid)]
    else { return nil }
    let classID = classes.controlClass(of: object).classID
    if object === root {
      return Identity(classID: classID, oid: oid, owner: nil, role: NMOSOcaControlMapping.rootRole, object: root)
    }
    guard let owner = await owner(of: object, root: root),
          let block = await identity(of: NMOSOcaControlMapping.oid(of: owner))
    else { return nil }
    let role = await roles(in: block.object)[object.objectNumber] ?? role(of: object)
    return Identity(classID: classID, oid: oid, owner: block.oid, role: role, object: object)
  }

  /// The block an object is in: the root block for a manager, as MS-05-02 has it.
  private func owner(
    of object: SwiftOCADevice.OcaRoot,
    root: SwiftOCADevice.OcaRoot,
    managers: [SwiftOCADevice.OcaRoot]? = nil
  ) async -> OcaONo? {
    if object is SwiftOCADevice.OcaManager {
      let managers = if let managers { managers } else { await device.managers }
      return managers.contains { $0 === object } ? root.objectNumber : nil
    }
    guard let owner = (object as? any SwiftOCADevice.OcaOwnable)?.owner, owner != OcaInvalidONo else { return nil }
    return owner
  }

  /// A block's members, in order: the objects it owns and, for the root block, the managers.
  private func members(of block: SwiftOCADevice.OcaRoot) async -> [SwiftOCADevice.OcaRoot] {
    guard let container = block as? any OcaBlockContainer, let root = await device.rootBlock else { return [] }
    let managers = await device.managers
    let candidates = (block === root ? managers : []) + container.actionObjects
    // a manager the root block also lists is a member once
    var members = [SwiftOCADevice.OcaRoot]()
    var seen = Set<OcaONo>()
    for candidate in candidates where seen.insert(candidate.objectNumber).inserted {
      if await owner(of: candidate, root: root, managers: managers) == block.objectNumber {
        members.append(candidate)
      }
    }
    return members
  }

  /// An object's OCA role as MS-05-02 allows one, or a standard class's fixed role where
  /// it has one.
  private func role(of object: SwiftOCADevice.OcaRoot) -> String {
    NcStandardModel.fixedRole(of: classes.controlClass(of: object).classID) ?? object.ncRole
  }

  /// The role each of a block's members is presented under: its oid is appended where a
  /// sibling before it has the same role, as roles are unique within a block. Worked out
  /// together and kept for as long as the block has the same members, so that listing
  /// a block is not quadratic in its size.
  private func roles(in block: SwiftOCADevice.OcaRoot) async -> [OcaONo: String] {
    // what the block lists, which is cheap to read, says whether what is kept still stands
    let listed = await listedMembers(of: block)
    if let kept = roles[block.objectNumber], kept.members == listed { return kept.roles }
    let members = await members(of: block)
    var taken = Set<String>()
    var roles = [OcaONo: String]()
    for member in members {
      let role = role(of: member)
      roles[member.objectNumber] = taken.insert(role).inserted
        ? role : role + "_\(NMOSOcaControlMapping.oid(of: member.objectNumber))"
    }
    self.roles[block.objectNumber] = (listed, roles)
    return roles
  }

  /// The object numbers a block lists, and for the root block the managers the device
  /// manager lists, before it is asked which of them are in the tree.
  private func listedMembers(of block: SwiftOCADevice.OcaRoot) async -> [OcaONo] {
    guard let container = block as? any OcaBlockContainer else { return [] }
    let managers = block === (await device.rootBlock) ? await device.deviceManager?.managers.map(\.objectNumber) ?? [] : []
    return managers + container.actionObjects.map(\.objectNumber)
  }

  private func registerEndpoint() async {
    if let registration { return await registration.value }
    let registration = Task { @OcaDevice [device, endpoint, logger] in
      do { try await device.add(endpoint: endpoint) } catch {
        logger.error("not receiving events: the device refused the NMOS control endpoint: \(error)")
      }
    }
    self.registration = registration
    await registration.value
  }

  public func members(of block: Identity) async -> [Identity] {
    let roles = await roles(in: block.object)
    return await members(of: block.object).map { member in
      Identity(
        classID: classes.controlClass(of: member).classID,
        oid: NMOSOcaControlMapping.oid(of: member.objectNumber),
        owner: block.oid,
        role: roles[member.objectNumber] ?? role(of: member),
        object: member
      )
    }
  }

  /// The IS-04 resources an object stands for: the device for the root block, the node
  /// for the device manager, and a transport application's senders and receivers.
  public func touchpoints(of identity: Identity) async -> [NcTouchpoint]? {
    let object = identity.object
    guard let ids = await resourceIDs() else { return nil }
    if object.objectNumber == OcaRootBlockONo {
      return [NcTouchpoint(resourceType: "device", id: ids.device)]
    }
    if object is SwiftOCADevice.OcaDeviceManager {
      return [NcTouchpoint(resourceType: "node", id: ids.node)]
    }
    guard let application = object as? SwiftOCADevice.OcaMediaTransportApplication else { return nil }
    var touchpoints = [NcTouchpoint]()
    for endpoint in application.endpoints {
      let endpoint = NMOSOcaEndpoint(application: application, endpoint: endpoint)
      // only endpoints an adaptation presents are IS-04 resources
      guard await adaptations.adaptation(for: endpoint) != nil else { continue }
      touchpoints.append(NcTouchpoint(
        resourceType: endpoint.isSender ? "sender" : "receiver", id: endpoint.id(endpoint.kind, in: ids)
      ))
    }
    return touchpoints.isEmpty ? nil : touchpoints
  }

  // MARK: - Properties

  public func get(_ property: NcElementID, of identity: Identity, session: NcSession) async -> NcMethodResult {
    await get(property, of: identity, as: controller(for: session))
  }

  private func get(
    _ property: NcElementID,
    of identity: Identity,
    as controller: NMOSOcaControlController
  ) async -> NcMethodResult {
    let object = identity.object
    let controlClass = classes.controlClass(of: object)
    if property == .userLabel {
      guard let label = controlClass.label else {
        // no label is an empty one, as an OCA object's is
        return NcMethodResult(value: .string(await labels.label(of: object.objectNumber) ?? ""))
      }
      let binding = NMOSOcaPropertyBinding(value: .property(label, .string), isReadOnly: false)
      return await read(binding, of: object, as: controller)
    }
    guard let binding = controlClass.properties[property] else {
      return .error(.propertyNotImplemented, "No property \(property.level)p\(property.index)")
    }
    return await read(binding, of: object, as: controller)
  }

  /// The range of each bounded OCA property of the object. OCA keeps a range with the
  /// value, for the object and not its class, and its getter answers with both.
  public func runtimeConstraints(of identity: Identity, session: NcSession) async -> [NMOSJSONValue] {
    await constraints(of: identity, as: controller(for: session))
  }

  private func constraints(of identity: Identity, as controller: NMOSOcaControlController) async -> [NMOSJSONValue] {
    let controlClass = classes.controlClass(of: identity.object)
    var constraints = [NMOSJSONValue]()
    let properties = controlClass.properties.sorted { ($0.key.level, $0.key.index) < ($1.key.level, $1.key.index) }
    for (id, binding) in properties where !binding.isHidden {
      // a bounded property's getter names its value, then its lower and upper bounds
      guard case let .property(description, schema?, .none) = binding.value,
            description.flags.contains(.bounded), schema.isNumber, let getter = description.getMethodID
      else { continue }
      let (status, answer) = await send(getter, to: identity.object, as: controller)
      guard status == .ok, let answer else { continue }
      // a bound OCP.2 has to write as text is infinite, which is no bound
      func bound(_ name: String) -> NMOSJSONValue? {
        guard let oca = answer[name].flatMap({ try? NMOSJSONValue(ocp2: $0) }), oca.stringValue == nil else {
          return nil
        }
        return try? classes.datatypes.standard(from: oca, as: schema)
      }
      let minimum = bound(description.ocp2GetNames[1])
      let maximum = bound(description.ocp2GetNames[2])
      guard minimum != nil || maximum != nil else { continue }
      constraints.append(NcPropertyConstraintsNumber(propertyID: id, minimum: minimum, maximum: maximum).json)
    }
    return constraints
  }

  public func set(
    _ property: NcElementID,
    of identity: Identity,
    to value: NMOSJSONValue,
    session: NcSession
  ) async -> NcMethodResult {
    let controller = await controller(for: session)
    let object = identity.object, oid = identity.oid
    let controlClass = classes.controlClass(of: object)
    let result: NcMethodResult
    if property == .userLabel {
      guard value.isNull || value.stringValue != nil else {
        return .error(.parameterError, "A user label is a string or null")
      }
      // MS-05-02 has every object's label writable: one without an OCA label a controller
      // can set has it kept in the label store. Where there is an OCA label, what the
      // device says to writing it, a refusal included, is the session's answer.
      if let label = controlClass.label {
        let binding = NMOSOcaPropertyBinding(value: .property(label, .string), isReadOnly: false)
        result = await write(binding, of: object, value, as: controller)
      } else {
        await labels.setLabel(value.stringValue.flatMap { $0.isEmpty ? nil : $0 }, of: object.objectNumber)
        result = NcMethodResult()
      }
    } else if let binding = controlClass.properties[property] {
      result = await write(binding, of: object, value, as: controller)
      // nothing is notified of a hidden property
      if binding.isHidden { return result }
    } else {
      return .error(.propertyNotImplemented, "No property \(property.level)p\(property.index)")
    }
    if !result.status.isError {
      // the object's own notification may come later or, for a label kept here, never
      for subscriber in sessions.filter({ $0.value.subscribed.contains(oid) }).keys {
        await changed(property, of: identity, session: subscriber)
      }
    }
    return result
  }

  private func read(
    _ binding: NMOSOcaPropertyBinding,
    of object: SwiftOCADevice.OcaRoot,
    as controller: NMOSOcaControlController
  ) async -> NcMethodResult {
    let description = binding.description
    guard let getter = description.getMethodID else {
      return .error(.propertyNotImplemented, "\(description.name) cannot be read")
    }
    let (status, parameters) = await send(getter, to: object, as: controller)
    guard status == .ok else {
      return .error(status.ncStatus(.get), "Reading \(description.name) failed: \(status)")
    }

    do {
      switch binding.value {
      case let .component(_, field, schema):
        // the getter answers with the pair; this property is one member of it
        guard let answer = parameters?[field] else { throw NMOSOcaMissingAnswer() }
        return try NcMethodResult(value: classes.datatypes.standard(from: NMOSJSONValue(ocp2: answer), as: schema))
      case let .property(_, schema, ncForm):
        // a getter answers with named parameters; a record's fields name themselves
        var answer: Any? = parameters
        if let name = description.ocp2GetNames.first {
          answer = parameters?[name]
          if answer == nil, parameters?.count == 1 { answer = parameters?.values.first }
        }
        guard let answer else { throw NMOSOcaMissingAnswer() }
        let oca = try NMOSJSONValue(ocp2: answer)
        if let ncForm { return NcMethodResult(value: ncForm.ncValue(from: oca)) }
        guard let schema else { return NcMethodResult(value: oca) }
        return try NcMethodResult(value: classes.datatypes.standard(from: oca, as: schema))
      }
    } catch {
      return .error(.deviceError, "The value of \(description.name) cannot be presented: \(error)")
    }
  }

  private func write(
    _ binding: NMOSOcaPropertyBinding,
    of object: SwiftOCADevice.OcaRoot,
    _ value: NMOSJSONValue,
    as controller: NMOSOcaControlController
  ) async -> NcMethodResult {
    // whether it can be written is settled before whether the value is acceptable
    guard !binding.isReadOnly else { return .error(.readonly, "The property is read only") }
    let description: OcaDevicePropertyDescriptor
    var parameters = [String: Any]()
    do {
      switch binding.value {
      case let .property(property, schema, _):
        description = property
        var oca = value
        // MS-05-02 lets a label or a name be null where OCA has an empty string
        if value.isNull, schema == .string {
          oca = ""
        } else if let schema {
          oca = try classes.datatypes.oca(from: value, as: schema)
        }
        parameters[property.ocp2SetName] = oca.ocp2
      case let .component(property, field, schema):
        // the setter takes the pair, so the other component is sent back as it reads
        description = property
        guard let getter = property.getMethodID else { return .error(.readonly, "The property is read only") }
        let (status, pair) = await send(getter, to: object, as: controller)
        guard status == .ok, let pair else {
          return .error(status.ncStatus(.get), "Reading \(property.name) failed: \(status)")
        }
        parameters = pair
        parameters[field] = try classes.datatypes.oca(from: value, as: schema).ocp2
      }
    } catch {
      return .error(.parameterError, "The value is not of the property's type")
    }
    guard let setter = description.setMethodID else {
      return .error(.readonly, "The property is read only")
    }
    let (status, _) = await send(setter, to: object, parameters, as: controller)
    guard status == .ok else {
      return .error(status.ncStatus(.set), "Writing \(description.name) failed: \(status)")
    }
    return NcMethodResult()
  }

  // MARK: - Methods

  /// A method of one of the object's non-standard classes: the object model has already
  /// answered the standard ones, so what is not in the class is not a method.
  public func handleCommand(_ command: NcCommand, on identity: Identity, session: NcSession) async -> NcMethodResult {
    guard let method = classes.controlClass(of: identity.object).methods[command.methodID] else {
      return .error(.methodNotImplemented, "No method \(command.methodID.level)m\(command.methodID.index)")
    }
    return await send(method, to: identity.object, command.arguments, as: controller(for: session))
  }

  /// The arguments go to the OCA method by their OCP.2 names, so the device decodes and
  /// checks them as it would a controller's. One result is the result's `value`; several
  /// are its fields, by their OCP.2 names, as the method's result datatype describes them.
  private func send(
    _ method: NMOSOcaMethodBinding,
    to object: SwiftOCADevice.OcaRoot,
    _ arguments: [String: NMOSJSONValue],
    as controller: NMOSOcaControlController
  ) async -> NcMethodResult {
    var parameters = [String: Any]()
    for field in method.parameters {
      guard let argument = arguments[field.name] else {
        return .error(.parameterError, "Argument \(field.name) is missing")
      }
      do {
        parameters[field.name] = try classes.datatypes.oca(from: argument, as: field.schema).ocp2
      } catch {
        return .error(.parameterError, "Argument \(field.name) is not of its type")
      }
    }
    let (status, answer) = await send(method.methodID, to: object, parameters, as: controller)
    guard status == .ok else {
      return .error(status.ncStatus(.method), "Method \(method.methodID) failed: \(status)")
    }
    do {
      var results = [String: NMOSJSONValue]()
      for field in method.results {
        guard let result = answer?[field.name] else { throw NMOSOcaMissingAnswer() }
        results[field.name] = try classes.datatypes.standard(from: NMOSJSONValue(ocp2: result), as: field.schema)
      }
      switch method.results.count {
      case 0: return NcMethodResult()
      case 1: return NcMethodResult(value: results.values.first)
      default: return NcMethodResult(fields: results)
      }
    } catch {
      return .error(.deviceError, "The result of \(method.methodID) cannot be presented: \(error)")
    }
  }

  /// Sends an object one of its own methods as `controller`, which is how the device
  /// knows whose command it is.
  private func send(
    _ method: OcaMethodID,
    to object: SwiftOCADevice.OcaRoot,
    _ parameters: [String: Any] = [:],
    as controller: NMOSOcaControlController
  ) async -> (OcaStatus, [String: any Sendable]?) {
    await device.send(method, to: object.objectNumber, ocp2Parameters: parameters, from: controller)
  }

  // MARK: - Classes

  /// A class manager publishes the classes of every object in the model, so each has
  /// to have been looked at before they are listed; a class is described only once.
  public func descriptors() async -> (classes: [NcClassDescriptor], datatypes: [NcDatatypeDescriptor]) {
    for object in await device.objects.values {
      _ = classes.controlClass(of: object)
    }
    return (classes.descriptors, classes.datatypeDescriptors)
  }

  // MARK: - Sessions

  /// The controller a session is to the device, made when the session is first heard of.
  private func controller(for session: NcSession) async -> NMOSOcaControlController {
    if let known = sessions[session] { return known.controller }
    await registerEndpoint()
    // another call for the session may have made it while this one waited
    if let known = sessions[session] { return known.controller }
    let controller = NMOSOcaControlController(session: session) { [weak self] objectNumber, property in
      await self?.changed(property, of: objectNumber, session: session)
    }
    sessions[session] = Session(controller: controller)
    endpoint.add(controller)
    logger.debug("\(controller) is a controller of the device")
    return controller
  }

  /// The controller an open session is to the device, nil once the session has ended.
  func controller(of session: NcSession) -> NMOSOcaControlController? {
    sessions[session]?.controller
  }

  /// Lets go of what the device holds for the session's controller, as it does for any
  /// controller whose connection has gone, and has the device tell its delegate.
  public func sessionEnded(_ session: NcSession) async {
    listeners.withLock { $0.removeValue(forKey: session) }?.continuation.finish()
    guard let ended = sessions.removeValue(forKey: session) else { return }
    endpoint.remove(ended.controller)
    await device.expire(controller: ended.controller)
    logger.debug("\(ended.controller) is gone")
  }

  // MARK: - Events

  public nonisolated func notifications(for session: NcSession) -> AsyncStream<NcNotification> {
    let (stream, continuation) = AsyncStream<NcNotification>.makeStream()
    // a session asked again has its events go to the new stream, and the old one ends
    let id = UUID()
    listeners.withLock { $0.updateValue((id, continuation), forKey: session) }?.continuation.finish()
    continuation.onTermination = { [weak self] _ in
      self?.listeners.withLock { listeners in
        // only if it is still this stream's: a later one may have replaced it
        if listeners[session]?.id == id { listeners[session] = nil }
      }
    }
    return stream
  }

  /// Subscribes the session's controller to the property changes of the objects the
  /// session now wants, and drops its subscriptions to those it no longer does.
  public func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {
    let controller = await controller(for: session)
    var added = [NcOid: [OcaSubscriptionManagerSubscription]]()
    // the constraints as they are now, so that only a change to them is notified
    var constraints = [NcOid: NMOSJSONValue]()
    for oid in oids.subtracting(sessions[session]?.subscribed ?? []) {
      added[oid] = await subscriptions(to: oid)
      if let identity = await identity(of: oid) {
        let current = await self.constraints(of: identity, as: controller)
        constraints[oid] = current.isEmpty ? .null : .array(current)
      }
    }
    guard let state = sessions[session] else { return }
    let subscriptionManager = await device.subscriptionManager
    for (oid, subscriptions) in added where !state.subscribed.contains(oid) {
      for subscription in subscriptions {
        try? subscriptionManager?.addSubscription(subscription, for: controller)
      }
      sessions[session]?.subscriptions[oid] = subscriptions
      sessions[session]?.notified[oid, default: [:]][.runtimePropertyConstraints] = constraints[oid]
    }
    for oid in state.subscribed.subtracting(oids) {
      for subscription in sessions[session]?.subscriptions.removeValue(forKey: oid) ?? [] {
        subscriptionManager?.removeSubscription(subscription, for: controller)
      }
      sessions[session]?.notified[oid] = nil
    }
    sessions[session]?.subscribed = oids
  }

  /// One subscription for each property the object presents, so the device neither encodes
  /// nor sends the session's controller anything else, such as OcaLevelSensor's own 4.1.
  private func subscriptions(to oid: NcOid) async -> [OcaSubscriptionManagerSubscription] {
    guard let identity = await identity(of: oid) else { return [] }
    return classes.controlClass(of: identity.object).standardIDs.keys.map { property in
      .propertyChangeSubscription2(OcaPropertyChangeSubscription2(
        emitter: identity.object.objectNumber, property: property,
        notificationDeliveryMode: .normal, destinationInformation: OcaNetworkAddress()
      ))
    }
  }

  /// An OCA object reported to a session's controller that one of its properties changed.
  private func changed(_ property: OcaPropertyID, of objectNumber: OcaONo, session: NcSession) async {
    let oid = NMOSOcaControlMapping.oid(of: objectNumber)
    guard sessions[session]?.subscribed.contains(oid) == true, let identity = await identity(of: oid) else { return }
    let controlClass = classes.controlClass(of: identity.object)
    guard let id = controlClass.standardIDs[property] else { return }
    guard id != .members else {
      // the object model has the members' descriptors, and gives them to the notification
      notify(.members, of: oid, value: .null, session: session)
      return
    }
    await changed(id, of: identity, session: session)
    // a bounded property's range is in the object's runtime constraints, which change with it
    if case let .property(description, _, _)? = controlClass.properties[id]?.value, description.flags.contains(.bounded) {
      await changedConstraints(of: identity, session: session)
    }
  }

  private func changedConstraints(of identity: Identity, session: NcSession) async {
    guard let state = sessions[session] else { return }
    let oid = identity.oid
    let constraints = await constraints(of: identity, as: state.controller)
    let value: NMOSJSONValue = constraints.isEmpty ? .null : .array(constraints)
    guard sessions[session]?.notified[oid]?[.runtimePropertyConstraints] != value else { return }
    sessions[session]?.notified[oid, default: [:]][.runtimePropertyConstraints] = value
    notify(.runtimePropertyConstraints, of: oid, value: value, session: session)
  }

  private func notify(_ property: NcElementID, of oid: NcOid, value: NMOSJSONValue, session: NcSession) {
    let eventData = NcPropertyChangedEventData(propertyID: property, value: value)
    listeners.withLock { $0[session] }?.continuation.yield(NcNotification(oid: oid, eventData: eventData.json))
  }

  /// Notifies the session of the property's value as it now reads to it, unless that
  /// is what the session was notified of last.
  private func changed(_ property: NcElementID, of identity: Identity, session: NcSession) async {
    let oid = identity.oid
    guard let state = sessions[session], state.subscribed.contains(oid) else { return }
    let current = await get(property, of: identity, as: state.controller)
    guard !current.status.isError, let value = current.value,
          sessions[session]?.notified[oid]?[property] != value
    else { return }
    sessions[session]?.notified[oid, default: [:]][property] = value
    notify(property, of: oid, value: value, session: session)
  }
}

/// A getter or method that answered without the value it was asked for.
private struct NMOSOcaMissingAnswer: Error, CustomStringConvertible {
  var description: String { "the object returned nothing" }
}

/// What a command to an OCA object was sent for, which decides what not implemented means.
private enum NMOSOcaAccess {
  case get, set, method
}

private extension OcaStatus {
  /// The MS-05-02 status of an OCA command's status, the one mapping the bridge uses.
  func ncStatus(_ access: NMOSOcaAccess) -> NcMethodStatus {
    switch self {
    case .ok: .ok
    case .locked: .locked
    case .badFormat, .parameterError, .parameterOutOfRange: .parameterError
    case .badONo: .badOid
    case .notImplemented, .badMethod:
      switch access {
      // the Get method is there; it is the property's getter that is not
      case .get: .propertyNotImplemented
      // a setter that is declared but not implemented: the property cannot be set
      case .set: .readonly
      case .method: .methodNotImplemented
      }
    case .invalidRequest: .invalidRequest
    case .timeout: .timeout
    case .bufferOverflow, .outOfMemory: .bufferOverflow
    case .permissionDenied: .unauthorized
    case .busy: .notReady
    case .protocolVersionError: .badCommandFormat
    case .deviceError, .processingFailed, .partiallySucceeded: .deviceError
    }
  }
}
