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
  /// so that objects can point to the resources they stand for.
  convenience init(
    device: OcaDevice = .shared,
    mapping: NMOSOcaControlMapping = .standard,
    adaptations: NMOSOcaAdaptations = .standard,
    logger: Logger = Logger(label: "com.padl.NMOSOCABridge"),
    resourceIDs: @escaping NMOSOcaObjectSource.ResourceIDs = { nil }
  ) {
    self.init(
      source: NMOSOcaObjectSource(
        device: device, mapping: mapping, adaptations: adaptations, logger: logger, resourceIDs: resourceIDs
      )
    )
  }

  /// Where the class manager is, which is where the bridge makes it.
  var classManagerOid: NcOid { OcaClassManager.objectNumber }
}

/// The objects of an OCA device, presented as the mapping says. Properties are read and
/// written by sending the object its own accessor commands, as an OCP.2 controller
/// would, so locks, access checks and whatever the object does on a set all still apply.
///
/// Each control session is a controller of its own to the device, with the session's
/// peer as its identity: what a session may do, lock and hear of is what the device
/// allows a controller at that address, never what it allows the bridge.
@OcaDevice
public final class NMOSOcaObjectSource: NcObjectSource {
  public typealias ResourceIDs = @Sendable () async -> NMOSOcaResourceIDs?

  private struct Entry {
    let object: SwiftOCADevice.OcaRoot
    let owner: NcOid?
    let role: String
    let members: [NcOid]
  }

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
  private let mapping: NMOSOcaControlMapping
  private let adaptations: NMOSOcaAdaptations
  private let classes: NMOSOcaControlClasses
  private let logger: Logger
  private let resourceIDs: ResourceIDs

  private var sessions = [NcSession: Session]()
  /// Where the device finds the sessions' controllers.
  let endpoint = NMOSOcaControlEndpoint()
  private var isEndpointRegistered = false
  /// The bridge's own controller. It reads properties to see whether they can be
  /// presented, with no privilege, so that what it can read any session can; and it
  /// hears from the blocks and the device manager when the tree of objects changes.
  private var observer: NMOSOcaControlController?
  private var observed = Set<OcaONo>()
  /// The properties whose change is a change to the tree: members and managers.
  private var structural = Set<OcaPropertyID>()
  private var handle: OcaUint32 = 0
  private var index = [NcOid: Entry]()
  /// When the tree was last walked; nil when it has changed since, or never was.
  private var indexed: ContinuousClock.Instant?
  private var changes = 0
  /// How many times the tree has been walked.
  private(set) var walks = 0
  /// The walk under way, which a second session that needs one waits for.
  private var walking: Task<Void, Never>?
  private nonisolated let listeners = Mutex([NcSession: AsyncStream<NcNotification>.Continuation]())

  /// How long an oid that is not in the tree is taken not to exist. A block says what
  /// it contains a moment after it contains it, but a walk for every unknown oid would
  /// let anyone who asks for them keep the device busy.
  private static let indexLifetime = Duration.seconds(1)

  nonisolated init(
    device: OcaDevice,
    mapping: NMOSOcaControlMapping,
    adaptations: NMOSOcaAdaptations,
    logger: Logger,
    resourceIDs: @escaping ResourceIDs
  ) {
    self.device = device
    self.mapping = mapping
    self.adaptations = adaptations
    self.logger = logger
    self.resourceIDs = resourceIDs
    classes = NMOSOcaControlClasses(mapping: mapping, logger: logger)
  }

  /// The device holds the endpoint, and through it every subscription of the sessions'
  /// controllers and the bridge's own; they go with it.
  deinit {
    guard isEndpointRegistered else { return }
    let device = device, endpoint = endpoint
    Task { @OcaDevice in try? await device.remove(endpoint: endpoint) }
  }

  // MARK: - The tree

  private func entry(_ oid: NcOid) async -> Entry? {
    guard let indexed else {
      await walk()
      return index[oid]
    }
    if let entry = index[oid] { return entry }
    guard indexed.duration(to: .now) >= Self.indexLifetime else { return nil }
    await walk()
    return index[oid]
  }

  private func walk() async {
    if let walking { return await walking.value }
    let walking = Task { @OcaDevice in
      await self.walkTree()
      self.walking = nil
    }
    self.walking = walking
    await walking.value
  }

  /// Finds every object reachable from the root block, which MS-05-02 has contain the
  /// managers too. An object in two blocks is presented in the first it is found in.
  private func walkTree() async {
    var index = [NcOid: Entry]()
    guard let root = await device.rootBlock, let deviceManager = await device.deviceManager else {
      return
    }
    // the class manager is one of the managers listed below, so it is made first
    await registerEndpoint()
    let changes = changes
    walks += 1
    var managers: [SwiftOCADevice.OcaRoot] = [deviceManager]
    for manager in deviceManager.managers where manager.objectNumber != deviceManager.objectNumber {
      if let object: SwiftOCADevice.OcaRoot = await device.resolve(objectNumber: manager.objectNumber) {
        managers.append(object)
      }
    }

    // every object's class is described as it is found, the root block's here
    _ = await controlClass(of: root, role: mapping.rootRole)
    var pending: [(object: SwiftOCADevice.OcaRoot, owner: NcOid?, role: String)] =
      [(root, nil, mapping.rootRole)]
    var claimed: Set<NcOid> = [mapping.oid(of: root.objectNumber)]
    while !pending.isEmpty {
      let (object, owner, role) = pending.removeFirst()
      let oid = mapping.oid(of: object.objectNumber)
      var children = [SwiftOCADevice.OcaRoot]()
      if let block = object as? any OcaBlockContainer {
        children = (object === root ? managers : []) + block.actionObjects
      }

      var members = [NcOid]()
      var roles = Set<String>()
      for child in children {
        let childOid = mapping.oid(of: child.objectNumber)
        guard claimed.insert(childOid).inserted else { continue }
        let childRole = await nmosRole(of: child, oid: childOid, among: &roles)
        members.append(childOid)
        pending.append((child, oid, childRole))
      }
      index[oid] = Entry(object: object, owner: owner, role: role, members: members)
    }
    self.index = index
    // the walk stands until a block or the device manager says the tree has changed,
    // which one may have done while it was being walked
    let blocks = index.values.filter { $0.object is any OcaBlockContainer }.map(\.object.objectNumber)
    await observe(Set(blocks + [deviceManager.objectNumber]), deviceManager: deviceManager)
    indexed = changes == self.changes ? .now : nil
  }

  /// The role a child is presented under in its block, among the roles its siblings have
  /// taken: its OCA role without dots, as they separate role paths; a standard class's
  /// fixed role where it has one; and its oid appended where a sibling has the role.
  private func nmosRole(of child: SwiftOCADevice.OcaRoot, oid: NcOid, among roles: inout Set<String>) async -> String {
    var role = child.role.replacingOccurrences(of: ".", with: "_")
    // the class is described as it is found, under the role it was found with
    let classID = await controlClass(of: child, role: role).classID
    if let fixed = NcStandardModel.fixedRole(of: classID) { role = fixed }
    if !roles.insert(role).inserted {
      role += "_\(oid)"
      roles.insert(role)
    }
    return role
  }

  /// Observes the property changes of the objects that say what the tree contains.
  private func observe(_ objects: Set<OcaONo>, deviceManager: SwiftOCADevice.OcaDeviceManager) async {
    if structural.isEmpty {
      structural = Set(mapping.anchors.flatMap(\.properties).compactMap { property in
        if case let .members(id) = property.source { id } else { nil }
      })
      let managers = deviceManager.devicePropertyDescriptors.first { $0.name == mapping.managersProperty }
      if let managers { structural.insert(managers.propertyID) }
    }
    let observer = await describer()
    func subscription(_ objectNumber: OcaONo) -> OcaSubscriptionManagerSubscription {
      .subscription2(OcaSubscription2(
        event: OcaEvent(emitterONo: objectNumber, eventID: OcaPropertyChangedEventID),
        notificationDeliveryMode: .normal,
        destinationInformation: OcaNetworkAddress()
      ))
    }
    // the subscription manager holds every controller's subscriptions
    let subscriptionManager = await device.subscriptionManager
    for objectNumber in objects.subtracting(observed) {
      try? subscriptionManager?.addSubscription(subscription(objectNumber), for: observer)
    }
    for objectNumber in observed.subtracting(objects) {
      subscriptionManager?.removeSubscription(subscription(objectNumber), for: observer)
    }
    observed = objects
  }

  /// The bridge's controller, made and given to the device when it is first needed.
  private func describer() async -> NMOSOcaControlController {
    if let observer { return observer }
    await registerEndpoint()
    if let observer { return observer }
    let observer = NMOSOcaControlController(description: "ncp/bridge", flags: []) {
      [weak self] objectNumber, property in
      await self?.treeChanged(property, of: objectNumber)
    }
    self.observer = observer
    endpoint.add(observer)
    return observer
  }

  private func treeChanged(_ property: OcaPropertyID, of objectNumber: OcaONo) {
    guard structural.contains(property), observed.contains(objectNumber) else { return }
    changes += 1
    indexed = nil
  }

  private func registerEndpoint() async {
    guard !isEndpointRegistered else { return }
    isEndpointRegistered = true
    do { try await device.add(endpoint: endpoint) } catch {
      logger.error("the device would not take the NMOS control endpoint, so no events will arrive: \(error)")
    }
    do { _ = try await OcaClassManager.shared(on: device) } catch {
      logger.error("the device would not take the class manager: \(error)")
    }
  }

  public func identity(of oid: NcOid) async -> NcObjectIdentity? {
    guard let entry = await entry(oid) else { return nil }
    return await NcObjectIdentity(
      classID: controlClass(of: entry.object, role: entry.role).classID,
      oid: oid,
      owner: entry.owner,
      role: entry.role,
      touchpoints: touchpoints(of: entry.object)
    )
  }

  public func members(of block: NcOid) async -> [NcOid] {
    await entry(block)?.members ?? []
  }

  /// The IS-04 resources an object stands for: the device for the root block, the node
  /// for the device manager, and a transport application's senders and receivers.
  private func touchpoints(of object: SwiftOCADevice.OcaRoot) async -> [NcTouchpoint]? {
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
      let endpoint = NMOSOcaEndpoint(application: application, endpoint: endpoint, status: nil)
      // only endpoints an adaptation presents are IS-04 resources
      guard await adaptations.adaptation(for: endpoint) != nil else { continue }
      touchpoints.append(NcTouchpoint(
        resourceType: endpoint.isSender ? "sender" : "receiver", id: endpoint.id(endpoint.kind, in: ids)
      ))
    }
    return touchpoints.isEmpty ? nil : touchpoints
  }

  /// How the object's class is presented, worked out the first time one is met.
  private func controlClass(of object: SwiftOCADevice.OcaRoot, role: String) async -> NMOSOcaControlClass {
    let describer = await describer()
    return await classes.controlClass(of: object, role: role) { property, schema in
      await self.isWritable(property, schema: schema, of: object, as: describer)
    }
  }

  /// Whether the device lets a controller with no privilege set the property, found
  /// out without setting it. The object is asked whether the setter may be used; and
  /// the setter of a plain value is sent no value, which one that is implemented can
  /// only refuse as malformed.
  private func isWritable(
    _ property: OcaDevicePropertyDescriptor,
    schema: NMOSOcaSchema?,
    of object: SwiftOCADevice.OcaRoot,
    as describer: NMOSOcaControlController
  ) async -> Bool {
    guard let setter = property.setMethodID else { return false }
    handle &+= 1
    let command = Ocp1Command(
      handle: handle, targetONo: object.objectNumber, methodID: setter,
      parameters: OcaParameters(ocp2Parameters: [:])
    )
    do {
      try await object.ensureWritable(by: describer, command: command)
    } catch Ocp1Error.status(.permissionDenied) {
      return false
    } catch {
      // locked, or not ready: how things stand now, not what the property is
    }
    // only where no value cannot be mistaken for a value, as nil could for an optional
    guard let schema, schema.isPlain else { return true }
    let status = await device.handleCommand(command, from: describer).statusCode
    return status != .notImplemented && status != .permissionDenied
  }

  // MARK: - Properties

  public func get(_ property: NcElementID, of oid: NcOid, session: NcSession) async -> NcMethodResult {
    await get(property, of: oid, as: controller(for: session))
  }

  private func get(
    _ property: NcElementID,
    of oid: NcOid,
    as controller: NMOSOcaControlController
  ) async -> NcMethodResult {
    guard let entry = await entry(oid) else { return .error(.badOid, "No object with oid \(oid)") }
    let controlClass = await controlClass(of: entry.object, role: entry.role)
    if property == .userLabel {
      guard let label = controlClass.label else { return NcMethodResult(value: .null) }
      let binding = NMOSOcaPropertyBinding(value: .property(label, .string, .identity), isReadOnly: false)
      return await read(binding, of: entry.object, as: controller)
    }
    guard let binding = controlClass.properties[property] else {
      return .error(.propertyNotImplemented, "No property \(property.level)p\(property.index)")
    }
    return await read(binding, of: entry.object, as: controller)
  }

  /// The range of each bounded OCA property of the object. OCA keeps a range with the
  /// value, for the object and not its class, and its getter answers with both.
  public func runtimeConstraints(of oid: NcOid, session: NcSession) async -> [NMOSJSONValue] {
    guard let entry = await entry(oid) else { return [] }
    let controller = await controller(for: session)
    let controlClass = await controlClass(of: entry.object, role: entry.role)
    var constraints = [NMOSJSONValue]()
    let properties = controlClass.properties.sorted { ($0.key.level, $0.key.index) < ($1.key.level, $1.key.index) }
    for (id, binding) in properties {
      // a bounded property's getter names its value, then its lower and upper bounds
      guard case let .property(description, schema?, .identity) = binding.value,
            description.ocp2GetNames.count == 3, schema.isNumber, let getter = description.getMethodID
      else { continue }
      let (status, answer) = await send(getter, to: entry.object, as: controller)
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
    of oid: NcOid,
    to value: NMOSJSONValue,
    session: NcSession
  ) async -> NcMethodResult {
    let controller = await controller(for: session)
    guard let entry = await entry(oid) else { return .error(.badOid, "No object with oid \(oid)") }
    let controlClass = await controlClass(of: entry.object, role: entry.role)
    let result: NcMethodResult
    if property == .userLabel {
      guard value.isNull || value.stringValue != nil else {
        return .error(.parameterError, "A user label is a string or null")
      }
      // the label is the OCA label: an object without one a controller can set (a
      // manager) refuses, as nothing here could keep its label across a restart
      guard let label = controlClass.label else {
        return .error(.readonly, "\(entry.role) has no user label that can be set")
      }
      let binding = NMOSOcaPropertyBinding(value: .property(label, .string, .identity), isReadOnly: false)
      result = await write(binding, of: entry.object, value, as: controller)
    } else if let binding = controlClass.properties[property] {
      // what the class is described as, every object of it keeps to; and the classes
      // that share its ID have all to have been met before that is known
      if !controller.flags.contains(.isLocal) {
        await describeEveryObject()
        guard !classes.isRefused(property, of: controlClass) else {
          return .error(.readonly, "The property is read only")
        }
      }
      result = await write(binding, of: entry.object, value, as: controller)
    } else {
      return .error(.propertyNotImplemented, "No property \(property.level)p\(property.index)")
    }
    if !result.status.isError {
      // the object's own notification may come later or, for a label kept here, never
      for subscriber in sessions.filter({ $0.value.subscribed.contains(oid) }).keys {
        await changed(property, of: oid, session: subscriber)
      }
    }
    return result
  }

  private func read(
    _ binding: NMOSOcaPropertyBinding,
    of object: SwiftOCADevice.OcaRoot,
    as controller: NMOSOcaControlController
  ) async -> NcMethodResult {
    let description: OcaDevicePropertyDescriptor
    switch binding.value {
    case let .constant(value): return NcMethodResult(value: value)
    case let .property(property, _, _), let .component(property, _, _): description = property
    }
    guard let getter = description.getMethodID else {
      return .error(.propertyNotImplemented, "\(description.name) cannot be read")
    }
    let (status, parameters) = await send(getter, to: object, as: controller)
    // an OCA getter refuses to return nil, which here is simply a null value
    if status == .parameterOutOfRange { return NcMethodResult(value: .null) }
    guard status == .ok else {
      return .error(Self.status(status), "Reading \(description.name) failed: \(status)")
    }

    do {
      switch binding.value {
      case .constant:
        return .error(.deviceError, "No value")
      case let .component(_, field, schema):
        // the getter answers with the pair; this property is one member of it
        guard let answer = parameters?[field] else { throw NMOSOcaMissingAnswer() }
        return try NcMethodResult(value: classes.datatypes.standard(from: NMOSJSONValue(ocp2: answer), as: schema))
      case let .property(_, schema, transform):
        // a getter answers with named parameters; a record's fields name themselves
        var answer: Any? = parameters
        if let name = description.ocp2GetNames.first {
          answer = parameters?[name]
          if answer == nil, parameters?.count == 1 { answer = parameters?.values.first }
        }
        guard let answer else { throw NMOSOcaMissingAnswer() }
        let oca = try NMOSJSONValue(ocp2: answer)
        guard case .identity = transform, let schema else {
          return NcMethodResult(value: transform.standardValue(from: oca))
        }
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
      case .constant:
        return .error(.readonly, "The property is read only")
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
          return .error(Self.status(status), "Reading \(property.name) failed: \(status)")
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
    switch status {
    case .ok: return NcMethodResult()
    // OCA's ways of saying a property that has a setter may not be set
    case .permissionDenied, .notImplemented: return .error(.readonly, "\(description.name) cannot be written")
    default: return .error(Self.status(status), "Writing \(description.name) failed: \(status)")
    }
  }

  // MARK: - Methods

  /// A method of one of the object's non-standard classes: the object model has already
  /// answered the standard ones, so what is not in the class is not a method.
  public func invoke(
    oid: NcOid,
    methodID: NcElementID,
    arguments: [String: NMOSJSONValue],
    session: NcSession
  ) async -> NcMethodResult {
    guard let entry = await entry(oid) else { return .error(.badOid, "No object with oid \(oid)") }
    let controlClass = await controlClass(of: entry.object, role: entry.role)
    guard let method = controlClass.methods[methodID] else {
      return .error(.methodNotImplemented, "No method \(methodID.level)m\(methodID.index)")
    }
    return await invoke(method, on: entry.object, arguments, as: controller(for: session))
  }

  /// The arguments go to the OCA method by their OCP.2 names, so the device decodes and
  /// checks them as it would a controller's. One result is the result's `value`; several
  /// are its fields, by their OCP.2 names, as the method's result datatype describes them.
  private func invoke(
    _ method: NMOSOcaMethodBinding,
    on object: SwiftOCADevice.OcaRoot,
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
      return .error(Self.status(status), "Method \(method.methodID) failed: \(status)")
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
    handle &+= 1
    let command = Ocp1Command(
      handle: handle, targetONo: object.objectNumber, methodID: method,
      parameters: OcaParameters(ocp2Parameters: parameters)
    )
    let response = await device.handleCommand(command, from: controller)
    return (response.statusCode, response.parameters.ocp2Parameters)
  }

  /// `NcMethodStatus` for an OCA status that is not `ok`.
  private static func status(_ status: OcaStatus) -> NcMethodStatus {
    switch status {
    case .ok, .partiallySucceeded: .ok
    case .locked: .locked
    case .badFormat, .parameterError, .parameterOutOfRange: .parameterError
    case .badONo: .badOid
    case .notImplemented, .badMethod: .methodNotImplemented
    case .invalidRequest: .invalidRequest
    case .timeout: .timeout
    case .bufferOverflow, .outOfMemory: .bufferOverflow
    case .permissionDenied: .unauthorized
    case .busy: .notReady
    case .protocolVersionError: .badCommandFormat
    case .deviceError, .processingFailed: .deviceError
    }
  }

  // MARK: - Classes

  public func classes() async -> [NcClassDescriptor] {
    await describeEveryObject()
    return classes.descriptors
  }

  public func datatypes() async -> [NcDatatypeDescriptor] {
    await describeEveryObject()
    return classes.datatypes.descriptors
  }

  /// A class manager publishes the classes of every object in the model, so each has
  /// to have been looked at before they are listed. A walk looks at them all, and is
  /// needed again only when the tree has changed since the last.
  private func describeEveryObject() async {
    if indexed == nil { await walk() }
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
    listeners.withLock { $0.removeValue(forKey: session) }?.finish()
    guard let ended = sessions.removeValue(forKey: session) else { return }
    endpoint.remove(ended.controller)
    await device.expire(controller: ended.controller)
    logger.debug("\(ended.controller) is gone")
  }

  // MARK: - Events

  public nonisolated func notifications(for session: NcSession) -> AsyncStream<NcNotification> {
    let (stream, continuation) = AsyncStream<NcNotification>.makeStream()
    listeners.withLock { $0[session] = continuation }
    return stream
  }

  /// Subscribes the session's controller to the property changes of the objects the
  /// session now wants, and drops its subscriptions to those it no longer does.
  public func subscriptionsChanged(to oids: Set<NcOid>, session: NcSession) async {
    let controller = await controller(for: session)
    var added = [NcOid: [OcaSubscriptionManagerSubscription]]()
    for oid in oids.subtracting(sessions[session]?.subscribed ?? []) {
      added[oid] = await subscriptions(to: oid)
    }
    guard let state = sessions[session] else { return }
    let subscriptionManager = await device.subscriptionManager
    for (oid, subscriptions) in added where !state.subscribed.contains(oid) {
      for subscription in subscriptions {
        try? subscriptionManager?.addSubscription(subscription, for: controller)
      }
      sessions[session]?.subscriptions[oid] = subscriptions
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
    guard let entry = await entry(oid) else { return [] }
    let controlClass = await controlClass(of: entry.object, role: entry.role)
    return controlClass.standardIDs.keys.map { property in
      .propertyChangeSubscription2(OcaPropertyChangeSubscription2(
        emitter: entry.object.objectNumber, property: property,
        notificationDeliveryMode: .normal, destinationInformation: OcaNetworkAddress()
      ))
    }
  }

  /// An OCA object reported to a session's controller that one of its properties changed.
  private func changed(_ property: OcaPropertyID, of objectNumber: OcaONo, session: NcSession) async {
    let oid = mapping.oid(of: objectNumber)
    guard sessions[session]?.subscribed.contains(oid) == true, let entry = await entry(oid) else { return }
    let controlClass = await controlClass(of: entry.object, role: entry.role)
    guard let id = controlClass.standardIDs[property] else { return }
    await changed(id, of: oid, session: session)
  }

  /// Notifies the session of the property's value as it now reads to it, unless that
  /// is what the session was notified of last.
  private func changed(_ property: NcElementID, of oid: NcOid, session: NcSession) async {
    guard let state = sessions[session], state.subscribed.contains(oid) else { return }
    let current = await get(property, of: oid, as: state.controller)
    guard !current.status.isError, let value = current.value,
          sessions[session]?.notified[oid]?[property] != value
    else { return }
    sessions[session]?.notified[oid, default: [:]][property] = value
    let eventData = NcPropertyChangedEventData(propertyID: property, value: value)
    listeners.withLock { $0[session] }?.yield(NcNotification(oid: oid, eventData: eventData.json))
  }
}

/// A getter or method that answered without the value it was asked for.
private struct NMOSOcaMissingAnswer: Error, CustomStringConvertible {
  var description: String { "the object returned nothing" }
}

/// The controller a control session is to the device. It speaks OCP.2, so that values
/// arrive as JSON, and is named for the session's peer, which is what the device's
/// logs and locks know it by. Only a peer on a local socket is a local controller.
actor NMOSOcaControlController: OcaController, CustomStringConvertible {
  typealias Changed = @Sendable (OcaONo, OcaPropertyID) async -> Void

  nonisolated let flags: OcaControllerFlags
  nonisolated let description: String
  nonisolated var controlProtocol: OcaControlProtocol { .ocp2 }
  private let changed: Changed

  init(description: String, flags: OcaControllerFlags, changed: @escaping Changed) {
    self.description = description
    self.flags = flags
    self.changed = changed
  }

  /// As SwiftOCA has its own network controllers: one that can hold locks, and local
  /// only if it reached the device through a socket of the host's file system.
  init(session: NcSession, changed: @escaping Changed) {
    switch session.peer {
    case .local:
      self.init(description: "ncp/local/\(session)", flags: [.supportsLocking, .isLocal], changed: changed)
    case .ip, nil:
      self.init(description: "ncp/tcp/\(session)", flags: .supportsLocking, changed: changed)
    }
  }

  /// The only messages a device sends a controller unasked are notifications. Which
  /// object and property one is about is all that is taken from it, without decoding its
  /// value: the value is read afresh, the way the session's own Get would read it.
  func sendMessages(_ messages: [any Ocp1Message], type messageType: OcaMessageType) async throws {
    guard messageType == .ocaNtf2 else { return }
    for case let notification as Ocp1Notification2 in messages
      where notification.event.eventID == OcaPropertyChangedEventID
    {
      let property = try OcaEventDataCoding.propertyID(from: notification.eventData)
      await changed(notification.event.emitterONo, property)
    }
  }
}

/// Where the device finds the controllers of the open control sessions, to notify them.
final class NMOSOcaControlEndpoint: OcaDeviceEndpoint {
  private let sessions = Mutex([NMOSOcaControlController]())

  func add(_ controller: NMOSOcaControlController) {
    sessions.withLock { $0.append(controller) }
  }

  func remove(_ controller: NMOSOcaControlController) {
    sessions.withLock { $0.removeAll { $0 === controller } }
  }

  var controllers: [any OcaController] {
    get async { sessions.withLock { $0 } }
  }
}
