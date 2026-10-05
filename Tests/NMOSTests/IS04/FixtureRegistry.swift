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
import NMOS
import Synchronization
import XCTest

/// A Registration API as a node sees one, without a network: it keeps what is registered
/// with each registry address, answers as IS-04 says a registry does, and records the
/// calls so a test can check their order. A test can override any answer.
final class FixtureRegistry: Sendable {
  struct Call: Equatable, CustomStringConvertible {
    var registry: String
    var method: HTTPMethod
    /// `resource`, `resource/senders/<id>` or `health/nodes/<id>`.
    var path: String
    /// The `type` of a registered resource.
    var type: String?
    var id: String?

    var description: String {
      "\(method.rawValue) \(path)\(type.map { " \($0)" } ?? "")\(id.map { " \($0)" } ?? "") @\(registry)"
    }
  }

  typealias Override = @Sendable (Call) throws -> NMOSHTTPClientResponse?

  private struct State {
    var calls = [Call]()
    /// For each registry, the IDs registered of each type.
    var held = [String: [String: Set<String>]]()
    var override: Override?
  }

  private let state = Mutex(State())

  let client = FixtureHTTPClient()

  init() {
    // the node may still be saying goodbye when a test lets go of the registry, so the
    // client keeps it alive; the cycle lasts only as long as the test process
    client.respond { request in try self.respond(to: request) }
  }

  var calls: [Call] { state.withLock { $0.calls } }

  func calls(to registry: String) -> [Call] { calls.filter { $0.registry == registry } }

  /// Answers in place of the registry whenever it returns a response, or fails the
  /// request when it throws.
  func override(_ override: Override?) {
    state.withLock { $0.override = override }
  }

  func holds(_ type: String, _ id: NMOSID, registry: String = "registry:8010") -> Bool {
    state.withLock { $0.held[registry]?[type]?.contains(id.description) ?? false }
  }

  /// Forgets everything a registry held, as garbage collection does.
  func forget(registry: String = "registry:8010") {
    state.withLock { $0.held[registry] = nil }
  }

  /// Gives a registry a node it did not get from this run, as a restart leaves behind.
  func remember(_ type: String, _ id: NMOSID, registry: String = "registry:8010") {
    state.withLock { _ = $0.held[registry, default: [:]][type, default: []].insert(id.description) }
  }

  private func respond(to request: FixtureHTTPClient.Request) throws -> NMOSHTTPClientResponse {
    let registry = "\(request.url.host ?? ""):\(request.url.port ?? 80)"
    let prefix = "/x-nmos/registration/v1.3/"
    guard request.url.path.hasPrefix(prefix) else { return .init(status: 404) }
    var call = Call(registry: registry, method: request.method, path: String(request.url.path.dropFirst(prefix.count)))
    if let body = request.body, let json = try? NMOSJSONValue(data: body) {
      call.type = json["type"]?.stringValue
      call.id = json["data"]?["id"]?.stringValue
    }
    let override = state.withLock { state in
      state.calls.append(call)
      return state.override
    }
    if let response = try override?(call) { return response }

    let components = call.path.split(separator: "/").map(String.init)
    return state.withLock { state in
      var held = state.held[registry] ?? [:]
      defer { state.held[registry] = held }
      switch (call.method, components.first) {
      case (.POST, "resource"):
        guard let type = call.type, let id = call.id else { return .init(status: 400) }
        let inserted = held[type, default: []].insert(id).inserted
        return .init(status: inserted ? 201 : 200)
      case (.DELETE, "resource") where components.count == 3:
        let type = String(components[1].dropLast())
        guard held[type]?.remove(components[2]) != nil else { return .init(status: 404) }
        // removing a node removes everything registered under it
        if type == "node" { held = [:] }
        return .init(status: 204)
      case (.POST, "health") where components.count == 3:
        return .init(status: held["node"]?.contains(components[2]) == true ? 200 : 404)
      default:
        return .init(status: 404)
      }
    }
  }
}

/// A node, a device and one of each resource under it, referring to each other as the
/// data model requires.
struct FixtureResources {
  let node = NMOSID(UUID())
  let device = NMOSID(UUID())
  let source = NMOSID(UUID())
  let flow = NMOSID(UUID())
  let sender = NMOSID(UUID())
  let receiver = NMOSID(UUID())

  var nodeResource: NMOSNodeResource {
    NMOSNodeResource(
      id: node, label: "node", description: "", href: "http://192.0.2.1:8080/",
      api: .init(versions: [.v1_3], endpoints: [.init(host: "192.0.2.1", port: 8080)])
    )
  }

  var senderResource: NMOSSenderResource {
    NMOSSenderResource(
      id: sender, label: "sender", description: "", flowID: flow,
      transport: "urn:x-nmos:transport:rtp.mcast", deviceID: device, manifestHref: nil,
      interfaceBindings: [], subscription: .init(active: false)
    )
  }

  var all: [NMOSResource] {
    [
      .node(nodeResource),
      .device(NMOSDeviceResource(id: device, label: "device", description: "", nodeID: node)),
      .source(NMOSSourceResource(
        id: source, label: "source", description: "", deviceID: device, clockName: nil, channels: []
      )),
      .flow(NMOSFlowResource(
        id: flow, label: "flow", description: "", sourceID: source, deviceID: device,
        sampleRate: .init(numerator: 48000), mediaType: "audio/L24", bitDepth: 24
      )),
      .sender(senderResource),
      .receiver(NMOSReceiverResource(
        id: receiver, label: "receiver", description: "", deviceID: device,
        transport: "urn:x-nmos:transport:rtp", interfaceBindings: [], subscription: .init(active: false)
      )),
    ]
  }
}

/// Waits for something another task is doing, failing the test if it never happens.
func eventually(
  _ what: String,
  timeout: Duration = .seconds(3),
  file: StaticString = #filePath,
  line: UInt = #line,
  _ condition: () async -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  XCTFail("timed out waiting until \(what)", file: file, line: line)
}
