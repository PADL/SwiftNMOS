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

/// The IS-05 Connection API. It owns what the specification asks of every device:
/// staging, merging, scheduling, locking and keeping IS-04 in step. What an endpoint is
/// doing, and how to change it, it asks of the connection provider.
public actor NMOSConnectionAPI {
  /// v1.1 serves the transports IS-05 defines; v1.2 also serves any other.
  public static let versions: [NMOSAPIVersion] = [.v1_1, .v1_2]

  /// How far ahead an activation may be scheduled. IS-05 schedules to synchronise salvos,
  /// not for the far future, and the endpoint is locked to other requests until then.
  public static let maximumScheduleAhead: Int64 = 24 * 60 * 60

  /// The IS-04 device control type and the API path for a version, relative to the host.
  public static func control(_ version: NMOSAPIVersion) -> (type: String, path: String) {
    ("urn:x-nmos:control:sr-ctrl/\(version)", "/\(NMOSRouter.root)/connection/\(version)/")
  }

  private struct Key: Hashable, Sendable {
    let kind: NMOSResourceKind
    let id: NMOSID
  }

  private struct Entry {
    var staged: NMOSConnectionState
    /// Set while an activation is scheduled, which is also when the endpoint is locked.
    var stagedActivation = NMOSActivation.none
    var timer: Task<Void, Never>?
    /// What was last activated through this API, to tell its effect from other changes.
    var activated: Activated?
    var lastActive: NMOSConnectionState
    var activeActivation = NMOSActivation.none
  }

  /// An activation: the settings the client asked for, and what the endpoint then said it
  /// was doing, which is those settings as its transport writes them.
  private struct Activated {
    var asked: NMOSConnectionState
    var readBack: NMOSConnectionState
  }

  private enum Route: Sendable {
    case list, endpoint, constraints, staged, stage, active, transportFile, transportType
  }

  /// A request for an endpoint this API version does not serve; `location` is where it is.
  private struct VersionConflict: Error {
    let location: String
  }

  private let provider: any NMOSConnectionProvider
  private let store: NMOSResourceStore
  private let logger: Logger
  private let now: @Sendable () -> NMOSTimestamp

  private var entries = [Key: Entry]()
  private var locked = Set<Key>()
  private var waiting = [Key: [CheckedContinuation<Void, Never>]]()

  public init(
    provider: any NMOSConnectionProvider,
    store: NMOSResourceStore,
    logger: Logger = Logger(label: "com.padl.NMOS.Connection"),
    now: @escaping @Sendable () -> NMOSTimestamp = { .now() }
  ) {
    self.provider = provider
    self.store = store
    self.logger = logger
    self.now = now
  }

  // MARK: - Routes

  public func register(on router: NMOSRouter) async {
    // from here on a sender's or receiver's `subscription` is this API's alone to write
    await store.manageSubscriptions()
    for version in Self.versions {
      let base = "connection/\(version)"
      for kind in [NMOSResourceKind.sender, .receiver] {
        let single = "\(base)/single/\(kind.collection)"
        let routes: [(HTTPMethod, String, Route)] = [
          (.GET, single, .list),
          (.GET, "\(single)/{id}", .endpoint),
          (.GET, "\(single)/{id}/constraints", .constraints),
          (.GET, "\(single)/{id}/staged", .staged),
          (.PATCH, "\(single)/{id}/staged", .stage),
          (.GET, "\(single)/{id}/active", .active),
          (.GET, "\(single)/{id}/transporttype", .transportType),
        ] + (kind == .sender ? [(.GET, "\(single)/{id}/transportfile", .transportFile)] : [])
        for (method, pattern, route) in routes {
          await router.add(method, pattern) { [self] request in
            try await handle(route, kind, version, request)
          }
        }
        await router.add(.POST, "\(base)/bulk/\(kind.collection)") { [self] request in
          try await bulk(kind, version, request)
        }
      }
    }
  }

  private func handle(
    _ route: Route,
    _ kind: NMOSResourceKind,
    _ version: NMOSAPIVersion,
    _ request: NMOSRequest
  ) async throws -> HTTPResponse {
    do {
      if route == .list {
        var ids = [String]()
        for id in await provider.connections(kind) where await serves(kind, id, version) {
          ids.append("\(id)/")
        }
        return try .nmos(json: ids)
      }
      let key = try Key(kind: kind, id: request.id("id"))
      let transport = try await transport(key, version)
      switch route {
      case .list, .endpoint:
        let children = ["constraints/", "staged/", "active/"]
          + (kind == .sender ? ["transportfile/"] : []) + ["transporttype/"]
        return try .nmos(json: children)
      case .constraints:
        return try await .nmos(json: provider.constraints(kind, id: key.id))
      case .staged:
        // a request made during an activation waits for it, so it sees the outcome
        await lock(key)
        defer { unlock(key) }
        let entry = try await load(key)
        return try .nmos(json: entry.staged.json(kind, activation: entry.stagedActivation))
      case .stage:
        let (status, body) = try await stage(key, request.body(NMOSJSONValue.self), transport: transport)
        return try .nmos(json: body, status: status)
      case .active:
        return try await .nmos(json: active(key))
      case .transportType:
        return try .nmos(json: transport)
      case .transportFile:
        guard let file = try await provider.transportFile(sender: key.id), let data = file.data else {
          throw NMOSHTTPError.notFound("The sender has no transport file at present")
        }
        let headers: HTTPHeaders = [
          .contentType: file.type ?? "application/octet-stream",
          // transport files change, and a client must not patch from a stale one
          HTTPHeader("Cache-Control"): "no-cache",
        ]
        return HTTPResponse(statusCode: .ok, headers: headers, body: Data(data.utf8))
      }
    } catch let error as NMOSConnectionError {
      throw Self.httpError(error)
    } catch let conflict as VersionConflict {
      var response = HTTPResponse.nmos(error: .conflict("This resource is served by a later version of the API"))
      response.headers[HTTPHeader("Location")] = conflict.location
      return response
    }
  }

  private func bulk(
    _ kind: NMOSResourceKind,
    _ version: NMOSAPIVersion,
    _ request: NMOSRequest
  ) async throws -> HTTPResponse {
    guard let items = try await request.body(NMOSJSONValue.self).arrayValue else {
      throw NMOSHTTPError.badRequest("The request body must be an array")
    }
    let requests = try items.map { item -> (id: NMOSID, params: NMOSJSONValue) in
      guard let object = item.objectValue, object.count == 2, let params = object["params"],
            let string = object["id"]?.stringValue, let id = NMOSID(string)
      else {
        throw NMOSHTTPError.badRequest("Each element must have an `id` and `params`, and nothing else")
      }
      return (id, params)
    }
    // each endpoint answers as it would have alone; one failing does not stop the others
    var results = [NMOSJSONValue]()
    for (id, params) in requests {
      let key = Key(kind: kind, id: id)
      var result: [String: NMOSJSONValue] = ["id": .string(id.description)]
      do {
        let transport = try await transport(key, version)
        let (status, _) = try await stage(key, params, transport: transport)
        result["code"] = .integer(Int64(status.code))
      } catch {
        let failure = (error as? NMOSHTTPError) ?? (error as? NMOSConnectionError).map(Self.httpError)
          ?? (error is VersionConflict ? .conflict("This resource is served by a later version of the API")
            : .internalError("The request could not be completed", debug: "\(error)"))
        result["code"] = .integer(Int64(failure.status.code))
        result["error"] = .string(failure.message)
        result["debug"] = failure.debug.map { .string($0) } ?? .null
      }
      results.append(.object(result))
    }
    return try .nmos(json: results)
  }

  private static func httpError(_ error: NMOSConnectionError) -> NMOSHTTPError {
    switch error {
    case .notFound: .notFound("No such sender or receiver")
    case let .invalid(message): .badRequest(message)
    case let .locked(message): .locked(message)
    case .unsupportedAPIVersion: .conflict("This resource is served by a later version of the API")
    case let .failed(message): .internalError("The settings could not be applied", debug: message)
    }
  }

  // MARK: - Versions

  /// The earliest version that serves a transport, given without its subclassification:
  /// v1.1 for those it defines, v1.2 for any other, whatever namespace it is named in.
  public static func earliestVersion(serving transport: String) -> NMOSAPIVersion {
    NMOSConnectionValidation.transportsBeforeV1_2.contains(transport) ? .v1_1 : .v1_2
  }

  private func serves(_ kind: NMOSResourceKind, _ id: NMOSID, _ version: NMOSAPIVersion) async -> Bool {
    guard let transport = try? await provider.transportType(kind, id: id) else { return false }
    return version >= Self.earliestVersion(serving: transport)
  }

  /// The endpoint's transport type, having checked that it exists and that this version
  /// of the API serves it.
  private func transport(_ key: Key, _ version: NMOSAPIVersion) async throws -> String {
    let transport = try await provider.transportType(key.kind, id: key.id)
    guard version >= Self.earliestVersion(serving: transport) else {
      let path = Self.control(.v1_2).path + "single/\(key.kind.collection)/\(key.id)"
      throw VersionConflict(location: path)
    }
    return transport
  }

  // MARK: - State

  private func load(_ key: Key) async throws -> Entry {
    if let entry = entries[key] { return entry }
    let active = try await provider.active(key.kind, id: key.id)
    if let entry = entries[key] { return entry }
    let entry = Entry(staged: Self.staged(from: active, key.kind), lastActive: active)
    entries[key] = entry
    return entry
  }

  /// What is staged for an endpoint nobody has staged anything for: what it is doing.
  private static func staged(from active: NMOSConnectionState, _ kind: NMOSResourceKind) -> NMOSConnectionState {
    var staged = active
    staged.transportFile = kind == .receiver ? NMOSTransportFile() : nil
    return staged
  }

  private func active(_ key: Key) async throws -> NMOSJSONValue {
    var state = try await provider.active(key.kind, id: key.id)
    let entry = entries[key]
    if let activated = entry?.activated, Self.agrees(state, with: activated) {
      // the device does not know which NMOS resource its peer is; the client said
      state.peerID = state.peerID ?? activated.asked.peerID
      state.transportFile = state.transportFile ?? activated.asked.transportFile
      // what was activated is what is active, even on an endpoint that keeps no settings
      // while disabled; where the choice was left to the endpoint, it is the endpoint's
      state.transportParameters = zip(state.transportParameters, activated.asked.transportParameters).map {
        $0.merging($1.filter { $0.value != "auto" }) { _, asked in asked }
      }
    }
    if !state.masterEnable { state.peerID = nil }
    return state.json(key.kind, activation: entry?.activeActivation ?? .none)
  }

  /// Whether the endpoint is still doing what was activated: every setting that was
  /// asked for is in force. Settings left to the endpoint (`auto`) may be anything. A
  /// transport may write a setting differently from the client (an identifier in another
  /// case, the interface it has in place of the one named), so a setting is also in force
  /// while it reads as it did straight after the activation.
  private static func agrees(_ active: NMOSConnectionState, with activated: Activated) -> Bool {
    let asked = activated.asked
    guard active.masterEnable == asked.masterEnable else { return false }
    // a disabled endpoint need not hold on to the settings it was disabled with
    guard asked.masterEnable else { return true }
    guard active.transportParameters.count == asked.transportParameters.count else { return false }
    let readBack = activated.readBack.transportParameters
    return zip(active.transportParameters, asked.transportParameters).enumerated().allSatisfy { leg, legs in
      legs.1.allSatisfy { name, value in
        guard value != "auto" else { return true }
        guard let current = legs.0[name] else { return false }
        if NMOSConnectionValidation.equal(current, value) { return true }
        guard leg < readBack.count, let written = readBack[leg][name] else { return false }
        return NMOSConnectionValidation.equal(current, written)
      }
    }
  }

  // MARK: - Staging and activation

  private func stage(
    _ key: Key,
    _ body: NMOSJSONValue,
    transport: String
  ) async throws -> (HTTPStatusCode, NMOSJSONValue) {
    let request = try NMOSStageRequest(body, kind: key.kind)
    await lock(key)
    defer { unlock(key) }

    let constraints = try await provider.constraints(key.kind, id: key.id)
    var entry = try await load(key)
    var staged = entry.staged
    if let masterEnable = request.masterEnable { staged.masterEnable = masterEnable }
    if let peerID = request.peerID { staged.peerID = peerID }
    if let file = request.transportFile {
      staged.transportFile = file
      if file.data != nil,
         let implied = try await provider.transportParameters(from: file, receiver: key.id)
      {
        for (leg, parameters) in implied.enumerated() where leg < staged.transportParameters.count {
          staged.transportParameters[leg].merge(parameters) { _, new in new }
        }
      }
    }
    // applied after the transport file, so that where the two disagree the parameters win
    if let legs = request.transportParameters {
      guard legs.count == constraints.count, legs.count == staged.transportParameters.count else {
        throw NMOSHTTPError.badRequest("`transport_params` must have \(constraints.count) element(s), one per leg")
      }
      for (leg, parameters) in legs.enumerated() {
        for (name, value) in parameters {
          guard let constraint = constraints[leg][name] else {
            throw NMOSHTTPError.badRequest("Un-recognised parameter '\(name)'")
          }
          try NMOSConnectionValidation.check(
            name, value, constraint: constraint, transport: transport, kind: key.kind
          )
          staged.transportParameters[leg][name] = value
        }
      }
    }
    try await provider.validate(key.kind, id: key.id, staged: staged)
    // refused before anything is staged, so that a request that fails changes nothing
    var requested = request.activation
    if let activation = requested, let mode = activation.mode {
      requested?.activationTime = try activationTime(mode, requested: activation.requestedTime)
    }

    if entry.stagedActivation.mode != nil {
      // only a request that cancels the pending activation may change a locked endpoint
      guard let activation = request.activation, activation.mode == nil else {
        throw NMOSHTTPError.locked("An activation is scheduled; set the activation mode to null to cancel it")
      }
      entry.timer?.cancel()
      entry.timer = nil
      entry.stagedActivation = .none
    }
    let previous = entry.staged
    entry.staged = staged
    entries[key] = entry

    guard var activation = requested, let mode = activation.mode else {
      return (.ok, staged.json(key.kind, activation: .none))
    }
    if mode == .immediate {
      activation.requestedTime = nil
      do {
        try await activate(key, activation)
      } catch {
        // a request that fails changes nothing, so its settings do not stay staged
        entries[key]?.staged = previous
        throw error
      }
      return (.ok, staged.json(key.kind, activation: activation))
    }
    entry.stagedActivation = activation
    entry.timer = schedule(key, activation)
    entries[key] = entry
    return (.accepted, staged.json(key.kind, activation: activation))
  }

  /// When an activation is to happen. A requested time is the client's number, so the
  /// arithmetic on it must not trap; one too far ahead to schedule is a bad request.
  private func activationTime(_ mode: NMOSActivationMode, requested: NMOSTimestamp?) throws -> NMOSTimestamp {
    let now = now()
    guard mode.isScheduled else { return now }
    let refusal = NMOSHTTPError.badRequest(
      "`requested_time` is more than \(Self.maximumScheduleAhead) seconds ahead, further than can be scheduled"
    )
    guard let requested, requested.seconds >= 0 else {
      throw NMOSHTTPError.badRequest("A scheduled activation needs a `requested_time`")
    }
    if mode == .scheduledRelative {
      guard requested.seconds <= Self.maximumScheduleAhead else { throw refusal }
      let nanoseconds = Int64(now.nanoseconds) + Int64(requested.nanoseconds)
      let (seconds, overflow) = now.seconds.addingReportingOverflow(requested.seconds + nanoseconds / 1_000_000_000)
      guard !overflow else { throw refusal }
      return NMOSTimestamp(seconds: seconds, nanoseconds: Int32(nanoseconds % 1_000_000_000))
    }
    let (ahead, overflow) = requested.seconds.subtractingReportingOverflow(now.seconds)
    guard !overflow, ahead <= Self.maximumScheduleAhead else { throw refusal }
    return requested
  }

  private func schedule(_ key: Key, _ activation: NMOSActivation) -> Task<Void, Never> {
    let delay = activation.activationTime.map { Self.interval(from: now(), to: $0) } ?? .zero
    return Task { [weak self] in
      do { try await Task.sleep(for: max(delay, .zero)) } catch { return }
      await self?.fire(key, activation)
    }
  }

  private func fire(_ key: Key, _ activation: NMOSActivation) async {
    await lock(key)
    defer { unlock(key) }
    // cancelled, or replaced by another, while this one waited
    guard entries[key]?.stagedActivation == activation else { return }
    do {
      try await activate(key, activation)
    } catch {
      logger.warning("scheduled activation of \(key.kind.rawValue) \(key.id) failed: \(error)")
      entries[key]?.stagedActivation = .none
      entries[key]?.timer = nil
    }
  }

  /// Applies what is staged. The caller holds the endpoint's lock.
  private func activate(_ key: Key, _ activation: NMOSActivation) async throws {
    guard let staged = entries[key]?.staged else { throw NMOSConnectionError.notFound }
    let active: NMOSConnectionState
    do {
      active = try await provider.activate(key.kind, id: key.id, staged: staged)
    } catch let error as NMOSConnectionError {
      throw Self.httpError(error)
    }
    guard var entry = entries[key] else { return }
    entry.activated = Activated(asked: staged, readBack: active)
    entry.lastActive = active
    entry.activeActivation = activation
    entry.stagedActivation = .none
    entry.timer = nil
    entries[key] = entry
    // an activation gives the resource a new version even if its subscription is the same
    await store.setSubscription(
      key.kind, id: key.id, active: active.masterEnable, peer: active.peerID ?? staged.peerID, touch: true
    )
  }

  // MARK: - Changes made elsewhere

  /// Observes changes the provider reports, so that `/active` and IS-04 show what the
  /// device is doing however it came to be doing it. Runs until the task is cancelled.
  public func run() async {
    await store.manageSubscriptions()
    let resources = await store.changes()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await change in self.provider.connectionChanges() {
          await self.observe(Key(kind: change.kind, id: change.id))
        }
      }
      group.addTask {
        // whatever describes the device does not say what a sender or receiver is
        // connected to, so each one is given its `subscription` when it appears
        for kind in [NMOSResourceKind.sender, .receiver] {
          for resource in await self.store.resources(kind) {
            await self.adopt(Key(kind: kind, id: resource.id))
          }
        }
        for await change in resources where change.change == .added {
          guard change.kind == .sender || change.kind == .receiver else { continue }
          await self.adopt(Key(kind: change.kind, id: change.id))
        }
      }
    }
  }

  /// Gives a resource that has just appeared the `subscription` its endpoint has now.
  private func adopt(_ key: Key) async {
    await lock(key)
    defer { unlock(key) }
    guard let active = try? await provider.active(key.kind, id: key.id) else { return }
    var peer = active.peerID
    if peer == nil, let activated = entries[key]?.activated, Self.agrees(active, with: activated) {
      peer = activated.asked.peerID
    }
    await store.setSubscription(key.kind, id: key.id, active: active.masterEnable, peer: peer)
  }

  private func observe(_ key: Key) async {
    await lock(key)
    defer { unlock(key) }
    guard let active = try? await provider.active(key.kind, id: key.id) else {
      // the endpoint has gone, and with it anything staged or scheduled for it
      entries[key]?.timer?.cancel()
      entries[key] = nil
      return
    }
    guard var entry = entries[key] else {
      entries[key] = Entry(staged: Self.staged(from: active, key.kind), lastActive: active)
      await store.setSubscription(key.kind, id: key.id, active: active.masterEnable, peer: active.peerID)
      return
    }
    guard entry.lastActive != active else { return }
    entry.lastActive = active
    if let activated = entry.activated, Self.agrees(active, with: activated) {
      // still what this API activated; only values the endpoint chose have moved
    } else {
      entry.activated = nil
      entry.activeActivation = NMOSActivation(mode: .immediate, activationTime: now())
      if entry.stagedActivation.mode == nil {
        entry.staged = Self.staged(from: active, key.kind)
      }
    }
    entries[key] = entry
    await store.setSubscription(
      key.kind, id: key.id, active: active.masterEnable, peer: active.peerID ?? entry.activated?.asked.peerID,
      touch: true
    )
  }

  // MARK: - Serialising work on an endpoint

  private func lock(_ key: Key) async {
    guard locked.contains(key) else {
      locked.insert(key)
      return
    }
    await withCheckedContinuation { waiting[key, default: []].append($0) }
  }

  private func unlock(_ key: Key) {
    guard var queue = waiting[key], !queue.isEmpty else {
      locked.remove(key)
      return
    }
    // the lock passes straight to the longest waiter
    let next = queue.removeFirst()
    waiting[key] = queue.isEmpty ? nil : queue
    next.resume()
  }

  // MARK: - Time

  /// The time from `start` to `end`, neither of which need be a time anyone would ask for.
  private static func interval(from start: NMOSTimestamp, to end: NMOSTimestamp) -> Duration {
    let (seconds, overflow) = end.seconds.subtractingReportingOverflow(start.seconds)
    guard !overflow else { return end.seconds < start.seconds ? .zero : .seconds(maximumScheduleAhead) }
    return .seconds(seconds) + .nanoseconds(Int64(end.nanoseconds) - Int64(start.nanoseconds))
  }
}
