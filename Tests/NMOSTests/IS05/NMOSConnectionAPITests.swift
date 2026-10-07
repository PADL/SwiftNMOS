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
import XCTest

/// The Connection API over a provider held in memory, against AMWA IS-05 v1.2 and its
/// example documents (Apache 2.0).
final class NMOSConnectionAPITests: XCTestCase {
  private var provider: FixtureConnectionProvider!
  private var store: NMOSResourceStore!
  private var api: NMOSConnectionAPI!
  private var router: NMOSRouter!
  private var runTask: Task<Void, Never>?

  private let sender = NMOSID("0a174530-e3cf-11e6-bf01-fe55135034f3")!
  private let receiver = NMOSID("7a3ebebe-0405-11e7-93ae-92361f002671")!
  private let danteReceiver = NMOSID("7a3ec21a-0405-11e7-93ae-92361f002671")!
  private let peer = NMOSID("5709255c-c0ae-4e1e-99a0-e872e83e48e0")!
  private let device = NMOSID("58f6b536-ca4c-43fd-880a-9df2501fc125")!

  private static let senderParameters: NMOSTransportParameters = [
    "source_ip": "192.168.200.10", "destination_ip": "232.105.26.177",
    "source_port": 5000, "destination_port": 5000, "rtp_enabled": true,
  ]
  private static let receiverParameters: NMOSTransportParameters = [
    "source_ip": .null, "multicast_ip": .null, "interface_ip": "192.168.200.15",
    "destination_port": 5004, "rtp_enabled": true,
  ]

  override func setUp() async throws {
    provider = FixtureConnectionProvider()
    provider.add(.init(
      kind: .sender,
      constraints: [[
        "source_ip": .fixed("192.168.200.10"), "destination_ip": .init(),
        "source_port": .fixed(5000), "destination_port": .init(maximum: 49150, minimum: 5000),
        "rtp_enabled": .init(),
      ]],
      active: .init(masterEnable: true, transportParameters: [Self.senderParameters]),
      transportFile: .init(data: "v=0\r\n", type: NMOSTransportFile.sdpType)
    ), id: sender)
    provider.add(.init(
      kind: .receiver,
      constraints: [[
        "source_ip": .init(), "multicast_ip": .init(), "destination_port": .init(),
        "interface_ip": .init(enum: ["192.168.200.15"]), "rtp_enabled": .init(),
      ]],
      active: .init(masterEnable: false, transportParameters: [Self.receiverParameters]),
      impliedParameters: [["multicast_ip": "232.250.98.80", "source_ip": "172.29.226.25", "destination_port": 5010]]
    ), id: receiver)
    provider.add(.init(
      kind: .receiver,
      transportType: "urn:x-nmos:transport:dante",
      constraints: [["device_name": .init(), "channel_name": .init()]],
      active: .init(masterEnable: false, transportParameters: [["device_name": .null, "channel_name": .null]])
    ), id: danteReceiver)

    store = NMOSResourceStore()
    await store.upsert(.sender(.init(
      id: sender, label: "Tx", description: "", flowID: nil, transport: "urn:x-nmos:transport:rtp.mcast",
      deviceID: device, manifestHref: nil, interfaceBindings: ["eth0"],
      subscription: .init(active: true)
    )))
    await store.upsert(.receiver(.init(
      id: receiver, label: "Rx", description: "", deviceID: device,
      transport: "urn:x-nmos:transport:rtp", interfaceBindings: ["eth0"], subscription: .init(active: false)
    )))

    api = NMOSConnectionAPI(provider: provider, store: store)
    router = NMOSRouter()
    await api.register(on: router)
    runTask = Task { [api] in await api!.run() }
  }

  override func tearDown() async throws {
    runTask?.cancel()
  }

  private func send(
    _ method: HTTPMethod,
    _ path: String,
    _ body: NMOSJSONValue? = nil
  ) async throws -> (status: HTTPStatusCode, json: NMOSJSONValue?, response: HTTPResponse) {
    let request = try HTTPRequest(
      method: method, version: .http11, path: "/x-nmos/connection/\(path)", query: [], headers: [:],
      body: HTTPBodySequence(data: body?.data() ?? Data())
    )
    let response = try await router.handleRequest(request)
    let data = try await response.bodyData
    let json = response.headers[.contentType] == "application/json" ? try NMOSJSONValue(data: data) : nil
    return (response.statusCode, json, response)
  }

  private func receiverSubscription() async -> (NMOSReceiverResource.Subscription, NMOSTimestamp)? {
    guard case let .receiver(resource) = await store.resource(.receiver, id: receiver) else { return nil }
    return (resource.subscription, resource.version)
  }

  // MARK: - Structure

  func testListsEachLevelAsTheSchemasRequire() async throws {
    let versions = try await send(.GET, "")
    XCTAssertEqual(versions.json, ["v1.1/", "v1.2/"])
    for version in ["v1.1", "v1.2"] {
      let base = try await send(.GET, "\(version)/")
      XCTAssertEqual(base.json, ["bulk/", "single/"])
      let bulk = try await send(.GET, "\(version)/bulk")
      XCTAssertEqual(bulk.json, ["receivers/", "senders/"])
      let single = try await send(.GET, "\(version)/single/")
      XCTAssertEqual(single.json, ["receivers/", "senders/"])
      let senders = try await send(.GET, "\(version)/single/senders/")
      XCTAssertEqual(senders.json, [.string("\(sender)/")])
      let senderRoot = try await send(.GET, "\(version)/single/senders/\(sender)")
      XCTAssertEqual(
        senderRoot.json, ["constraints/", "staged/", "active/", "transportfile/", "transporttype/"]
      )
      let receiverRoot = try await send(.GET, "\(version)/single/receivers/\(receiver)/")
      XCTAssertEqual(receiverRoot.json, ["constraints/", "staged/", "active/", "transporttype/"])
    }
  }

  func testBulkEndpointsRefuseGet() async throws {
    let result = try await send(.GET, "v1.2/bulk/senders")
    XCTAssertEqual(result.status, .methodNotAllowed)
    XCTAssertEqual(result.json?["code"], 405)
  }

  func testUnknownEndpointsAreNotFound() async throws {
    let unknown = NMOSID(UUID())
    for path in ["", "/constraints", "/staged", "/active", "/transporttype", "/transportfile"] {
      let result = try await send(.GET, "v1.2/single/senders/\(unknown)\(path)")
      XCTAssertEqual(result.status, .notFound, path)
      XCTAssertEqual(result.json?["code"], 404, path)
    }
    // a receiver is not a sender, and a malformed ID names nothing
    let wrongKind = try await send(.GET, "v1.2/single/senders/\(receiver)/staged")
    XCTAssertEqual(wrongKind.status, .notFound)
    let malformed = try await send(.GET, "v1.2/single/receivers/not-a-uuid/staged")
    XCTAssertEqual(malformed.status, .notFound)
    let patch = try await send(.PATCH, "v1.2/single/receivers/\(unknown)/staged", ["master_enable": true])
    XCTAssertEqual(patch.status, .notFound)
  }

  func testVendorTransportsNeedV1_2() async throws {
    let listed = try await send(.GET, "v1.2/single/receivers")
    XCTAssertEqual(listed.json, [.string("\(receiver)/"), .string("\(danteReceiver)/")])
    let older = try await send(.GET, "v1.1/single/receivers")
    XCTAssertEqual(older.json, [.string("\(receiver)/")])

    for path in ["", "/constraints", "/staged", "/active", "/transporttype"] {
      let result = try await send(.GET, "v1.1/single/receivers/\(danteReceiver)\(path)")
      XCTAssertEqual(result.status, .conflict, path)
      XCTAssertEqual(
        result.response.headers[HTTPHeader("Location")],
        "/x-nmos/connection/v1.2/single/receivers/\(danteReceiver)", path
      )
    }
    let type = try await send(.GET, "v1.2/single/receivers/\(danteReceiver)/transporttype")
    XCTAssertEqual(type.json, "urn:x-nmos:transport:dante")
    let patch = try await send(.PATCH, "v1.1/single/receivers/\(danteReceiver)/staged", ["master_enable": true])
    XCTAssertEqual(patch.status, .conflict)
  }

  func testTransportTypeAndConstraints() async throws {
    let type = try await send(.GET, "v1.1/single/senders/\(sender)/transporttype")
    XCTAssertEqual(type.json, "urn:x-nmos:transport:rtp")
    let constraints = try await send(.GET, "v1.1/single/senders/\(sender)/constraints")
    XCTAssertEqual(constraints.json, [[
      "source_ip": ["enum": ["192.168.200.10"]], "destination_ip": [:], "source_port": ["enum": [5000]],
      "destination_port": ["minimum": 5000, "maximum": 49150], "rtp_enabled": [:],
    ]])
  }

  func testTransportFile() async throws {
    let file = try await send(.GET, "v1.1/single/senders/\(sender)/transportfile")
    XCTAssertEqual(file.status, .ok)
    XCTAssertEqual(file.response.headers[.contentType], "application/sdp")
    XCTAssertEqual(file.response.headers[HTTPHeader("Cache-Control")], "no-cache")
    let body = try await file.response.bodyData
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "v=0\r\n")

    provider.setTransportFile(nil, sender: sender)
    let none = try await send(.GET, "v1.1/single/senders/\(sender)/transportfile")
    XCTAssertEqual(none.status, .notFound)
    XCTAssertEqual(none.json?["code"], 404)
  }

  // MARK: - Staged and active

  func testStagedAndActiveStartAsWhatTheEndpointIsDoing() async throws {
    let staged = try await send(.GET, "v1.2/single/receivers/\(receiver)/staged")
    let expected: NMOSJSONValue = [
      "sender_id": .null, "master_enable": false,
      "activation": ["mode": .null, "requested_time": .null, "activation_time": .null],
      "transport_file": ["data": .null, "type": .null],
      "transport_params": [.object(Self.receiverParameters)],
    ]
    XCTAssertEqual(staged.json, expected)
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json, expected)

    // a sender has no transport file member
    let sender = try await send(.GET, "v1.2/single/senders/\(sender)/staged")
    XCTAssertEqual(sender.json, [
      "receiver_id": .null, "master_enable": true,
      "activation": ["mode": .null, "requested_time": .null, "activation_time": .null],
      "transport_params": [.object(Self.senderParameters)],
    ])
  }

  func testStagingMergesWithoutActivating() async throws {
    let path = "v1.2/single/receivers/\(receiver)/staged"
    let first = try await send(.PATCH, path, ["transport_params": [["multicast_ip": "232.105.26.177"]]])
    XCTAssertEqual(first.status, .ok)
    XCTAssertEqual(first.json?["activation"]?["mode"], .null)
    let second = try await send(.PATCH, path, ["sender_id": .string(peer.description), "master_enable": true])
    XCTAssertEqual(second.status, .ok)

    // only what each request named has changed
    var parameters = Self.receiverParameters
    parameters["multicast_ip"] = "232.105.26.177"
    XCTAssertEqual(second.json?["transport_params"], [.object(parameters)])
    XCTAssertEqual(second.json?["sender_id"], .string(peer.description))
    XCTAssertEqual(second.json?["master_enable"], true)
    let staged = try await send(.GET, path)
    XCTAssertEqual(staged.json, second.json)

    XCTAssertTrue(provider.activations.isEmpty)
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
    XCTAssertEqual(active.json?["transport_params"], [.object(Self.receiverParameters)])
  }

  func testImmediateActivation() async throws {
    let before = await receiverSubscription()
    let result = try await send(.PATCH, "v1.2/single/receivers/\(receiver)/staged", [
      "sender_id": .string(peer.description), "master_enable": true,
      "activation": ["mode": "activate_immediate"],
      "transport_params": [["multicast_ip": "232.105.26.177", "destination_port": "auto"]],
    ])
    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(result.json?["activation"]?["mode"], "activate_immediate")
    XCTAssertEqual(result.json?["activation"]?["requested_time"], .null)
    let time = try XCTUnwrap(result.json?["activation"]?["activation_time"]?.stringValue)
    XCTAssertNotNil(NMOSTimestamp(time))

    XCTAssertEqual(provider.activations.count, 1)
    XCTAssertEqual(provider.activations.first?.staged.transportParameters.first?["destination_port"], "auto")

    // once the response is sent the staged activation is over; the active one records it
    let staged = try await send(.GET, "v1.2/single/receivers/\(receiver)/staged")
    XCTAssertEqual(staged.json?["activation"], ["mode": .null, "requested_time": .null, "activation_time": .null])
    XCTAssertEqual(staged.json?["master_enable"], true)
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["activation"]?["mode"], "activate_immediate")
    XCTAssertEqual(active.json?["activation"]?["activation_time"], .string(time))
    XCTAssertEqual(active.json?["sender_id"], .string(peer.description))
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["multicast_ip"], "232.105.26.177")

    let after = await receiverSubscription()
    XCTAssertEqual(after?.0, .init(senderID: peer, active: true))
    XCTAssertGreaterThan(try XCTUnwrap(after?.1), try XCTUnwrap(before?.1))
  }

  func testReactivationOfTheSameSettingsStillBumpsTheVersion() async throws {
    let path = "v1.2/single/receivers/\(receiver)/staged"
    let patch: NMOSJSONValue = ["master_enable": true, "activation": ["mode": "activate_immediate"]]
    let first = try await send(.PATCH, path, patch)
    XCTAssertEqual(first.status, .ok)
    let before = await receiverSubscription()
    let second = try await send(.PATCH, path, ["activation": ["mode": "activate_immediate"]])
    XCTAssertEqual(second.status, .ok)
    let after = await receiverSubscription()
    XCTAssertEqual(provider.activations.count, 2)
    XCTAssertEqual(after?.0, before?.0)
    XCTAssertGreaterThan(try XCTUnwrap(after?.1), try XCTUnwrap(before?.1))
  }

  func testDisablingClearsThePeerInIS04() async throws {
    let path = "v1.2/single/receivers/\(receiver)/staged"
    _ = try await send(.PATCH, path, [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
    ])
    let disabled = try await send(.PATCH, path, [
      "master_enable": false, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(disabled.status, .ok)
    let subscription = await receiverSubscription()
    XCTAssertEqual(subscription?.0, .init(senderID: nil, active: false))
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["sender_id"], .null)
  }

  func testTransportFileImpliesParametersWhichTheRequestOverrides() async throws {
    let file: NMOSJSONValue = ["data": "v=0\r\nm=audio 5010 RTP/AVP 97\r\n", "type": "application/sdp"]
    let result = try await send(.PATCH, "v1.2/single/receivers/\(receiver)/staged", [
      "transport_file": file, "transport_params": [["destination_port": 6000]],
    ])
    XCTAssertEqual(result.status, .ok)
    let parameters = result.json?["transport_params"]?.arrayValue?.first
    XCTAssertEqual(parameters?["multicast_ip"], "232.250.98.80")
    XCTAssertEqual(parameters?["source_ip"], "172.29.226.25")
    // where the file and the parameters disagree, the parameters win
    XCTAssertEqual(parameters?["destination_port"], 6000)
    XCTAssertEqual(parameters?["interface_ip"], "192.168.200.15")
    XCTAssertEqual(result.json?["transport_file"], file)

    let activated = try await send(.PATCH, "v1.2/single/receivers/\(receiver)/staged", [
      "master_enable": true, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(activated.status, .ok)
    XCTAssertEqual(provider.activations.last?.staged.transportFile?.type, "application/sdp")
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["transport_file"], file)
  }

  func testWhatIsActivatedOnADisabledEndpointIsStillWhatIsActive() async throws {
    // a device forgets the settings of a receiver that is not receiving
    provider.forgetsSettingsWhileDisabled = true
    let result = try await send(.PATCH, "v1.2/single/receivers/\(receiver)/staged", [
      "transport_params": [["destination_port": 6000]], "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(result.status, .ok)
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["destination_port"], 6000)
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["interface_ip"], "192.168.200.15")
  }

  // MARK: - Refusals

  func testRequestsThatDoNotMeetTheSchemaAreBadRequests() async throws {
    let path = "v1.2/single/receivers/\(receiver)/staged"
    let bad: [NMOSJSONValue] = [
      ["bad": "data"],
      ["master_enable": "yes"],
      ["sender_id": "not-a-uuid"],
      ["receiver_id": .null],
      ["activation": [:]],
      ["activation": ["mode": "activate_now"]],
      ["activation": ["mode": "activate_scheduled_relative"]],
      ["activation": ["mode": "activate_scheduled_absolute", "requested_time": "soon"]],
      ["transport_params": ["multicast_ip": "232.1.1.1"]],
      ["transport_params": [[:], [:]]],
      ["transport_params": [["frc_enabled": true]]],
      ["transport_params": [["multicast_ip": "not an address"]]],
      ["transport_params": [["destination_port": 70000]]],
      ["transport_params": [["destination_port": "5004"]]],
      ["transport_params": [["rtp_enabled": "true"]]],
      ["transport_params": [["interface_ip": "10.0.0.1"]]],
      ["transport_params": [["multicast_ip": ["232.1.1.1"]]]],
      ["transport_file": ["data": "v=0"]],
      [1, 2],
    ]
    for body in bad {
      let result = try await send(.PATCH, path, body)
      XCTAssertEqual(result.status, .badRequest, "\(body)")
      XCTAssertEqual(result.json?["code"], 400, "\(body)")
      XCTAssertNotNil(result.json?["error"]?.stringValue, "\(body)")
    }
    // none of them changed what is staged
    let staged = try await send(.GET, path)
    XCTAssertEqual(staged.json?["transport_params"], [.object(Self.receiverParameters)])

    // a sender has no transport file, and its constraints pin its source
    let senderPath = "v1.2/single/senders/\(sender)/staged"
    for body: NMOSJSONValue in [
      ["transport_file": ["data": .null, "type": .null]],
      ["transport_params": [["source_ip": "10.0.0.1"]]],
      ["transport_params": [["destination_port": 4000]]],
      ["transport_params": [["multicast_ip": "232.1.1.1"]]],
    ] {
      let result = try await send(.PATCH, senderPath, body)
      XCTAssertEqual(result.status, .badRequest, "\(body)")
    }
    let allowed = try await send(.PATCH, senderPath, [
      "transport_params": [["source_ip": "192.168.200.10", "destination_port": 5006, "destination_ip": "auto"]],
    ])
    XCTAssertEqual(allowed.status, .ok)
  }

  func testNullIsNotHeldToARangeOrAPattern() async throws {
    // as an unbound Milan listener presents itself: nothing set, and constraints on what may be
    let listener = NMOSID(UUID())
    provider.add(.init(
      kind: .receiver,
      transportType: "urn:x-nmos:transport:milan",
      constraints: [[
        "entity_id": .init(pattern: "^[0-9a-f]{16}$"), "stream_index": .init(maximum: 65535, minimum: 0),
        "mode": .init(enum: ["a", "b"]),
      ]],
      active: .init(masterEnable: false, transportParameters: [["entity_id": .null, "stream_index": .null, "mode": "a"]])
    ), id: listener)
    let path = "v1.2/single/receivers/\(listener)/staged"

    // a client may send back what it was given
    let staged = try await send(.GET, path)
    let unchanged = try await send(.PATCH, path, ["transport_params": try XCTUnwrap(staged.json?["transport_params"])])
    XCTAssertEqual(unchanged.status, .ok)
    XCTAssertEqual(unchanged.json?["transport_params"], staged.json?["transport_params"])

    // a value that is given is still held to them, and null is not one of an enumeration
    for parameters: NMOSJSONValue in [
      ["stream_index": 70000], ["stream_index": -1], ["stream_index": "3"], ["entity_id": "0x12"],
      ["entity_id": 5], ["mode": .null],
    ] {
      let result = try await send(.PATCH, path, ["transport_params": [parameters]])
      XCTAssertEqual(result.status, .badRequest, "\(parameters)")
    }
    let bound = try await send(.PATCH, path, [
      "transport_params": [["entity_id": "001122fffe334455", "stream_index": 3]],
    ])
    XCTAssertEqual(bound.status, .ok)
    // and what was set can be unset again
    let unbound = try await send(.PATCH, path, ["transport_params": [["entity_id": .null, "stream_index": .null]]])
    XCTAssertEqual(unbound.status, .ok)
  }

  func testBodiesThatAreNotJSONAreBadRequests() async throws {
    let request = HTTPRequest(
      method: .PATCH, version: .http11, path: "/x-nmos/connection/v1.2/single/receivers/\(receiver)/staged",
      query: [], headers: [:], body: HTTPBodySequence(data: Data("{master_enable".utf8))
    )
    let response = try await router.handleRequest(request)
    XCTAssertEqual(response.statusCode, .badRequest)
  }

  func testProviderFailuresMapToTheirStatusCodes() async throws {
    let path = "v1.2/single/receivers/\(receiver)/staged"
    let patch: NMOSJSONValue = ["master_enable": true, "activation": ["mode": "activate_immediate"]]
    for (error, status) in [
      (NMOSConnectionError.failed("the device refused"), HTTPStatusCode.internalServerError),
      (.invalid("no such stream"), .badRequest),
      (.locked("busy"), .locked),
    ] {
      provider.failActivations(with: error)
      let result = try await send(.PATCH, path, patch)
      XCTAssertEqual(result.status, status)
      XCTAssertEqual(result.json?["code"], .integer(Int64(status.code)))
    }
    // nothing became active, and IS-04 was not told that anything did
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["master_enable"], false)
    // nor does what the failed requests asked for stay staged
    let staged = try await send(.GET, path)
    XCTAssertEqual(staged.json?["master_enable"], false)
    let subscription = await receiverSubscription()
    XCTAssertEqual(subscription?.0, .init(senderID: nil, active: false))
  }

  // MARK: - Scheduled activation

  func testRelativeScheduledActivation() async throws {
    let path = "v1.2/single/receivers/\(receiver)/staged"
    let requested = NMOSTimestamp.now()
    let result = try await send(.PATCH, path, [
      "master_enable": true,
      "activation": ["mode": "activate_scheduled_relative", "requested_time": "0:300000000"],
    ])
    XCTAssertEqual(result.status, .accepted)
    XCTAssertEqual(result.json?["activation"]?["mode"], "activate_scheduled_relative")
    XCTAssertEqual(result.json?["activation"]?["requested_time"], "0:300000000")
    let time = try XCTUnwrap(result.json?["activation"]?["activation_time"]?.stringValue.flatMap(NMOSTimestamp.init))
    XCTAssertGreaterThan(time, requested)

    // pending: staged shows the activation, nothing is active, and the endpoint is locked
    let staged = try await send(.GET, path)
    XCTAssertEqual(staged.json?["activation"], result.json?["activation"])
    XCTAssertTrue(provider.activations.isEmpty)
    let locked = try await send(.PATCH, path, ["master_enable": false])
    XCTAssertEqual(locked.status, .locked)
    XCTAssertEqual(locked.json?["code"], 423)
    let another = try await send(.PATCH, path, ["activation": ["mode": "activate_immediate"]])
    XCTAssertEqual(another.status, .locked)

    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(provider.activations.count, 1)
    let after = try await send(.GET, path)
    XCTAssertEqual(after.json?["activation"], ["mode": .null, "requested_time": .null, "activation_time": .null])
    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["master_enable"], true)
    XCTAssertEqual(active.json?["activation"], result.json?["activation"])
    let subscription = await receiverSubscription()
    XCTAssertEqual(subscription?.0.active, true)
    // and it is unlocked again
    let unlocked = try await send(.PATCH, path, ["master_enable": false])
    XCTAssertEqual(unlocked.status, .ok)
  }

  func testAbsoluteScheduledActivationCanBeCancelled() async throws {
    let path = "v1.2/single/senders/\(sender)/staged"
    let now = NMOSTimestamp.now()
    let time = NMOSTimestamp(seconds: now.seconds + 3600, nanoseconds: now.nanoseconds)
    let result = try await send(.PATCH, path, [
      "master_enable": false,
      "activation": ["mode": "activate_scheduled_absolute", "requested_time": .string(time.description)],
    ])
    XCTAssertEqual(result.status, .accepted)
    // an absolute activation happens when it was asked to
    XCTAssertEqual(result.json?["activation"]?["activation_time"], .string(time.description))

    // cancelling may change other settings in the same request
    let cancelled = try await send(.PATCH, path, [
      "activation": ["mode": .null], "transport_params": [["destination_port": 5008]],
    ])
    XCTAssertEqual(cancelled.status, .ok)
    XCTAssertEqual(cancelled.json?["activation"], ["mode": .null, "requested_time": .null, "activation_time": .null])
    XCTAssertEqual(cancelled.json?["transport_params"]?.arrayValue?.first?["destination_port"], 5008)
    XCTAssertEqual(cancelled.json?["master_enable"], false)
    XCTAssertTrue(provider.activations.isEmpty)
    let unlocked = try await send(.PATCH, path, ["master_enable": true])
    XCTAssertEqual(unlocked.status, .ok)
  }

  func testAnActivationTimeAlreadyPastHappensAtOnce() async throws {
    let result = try await send(.PATCH, "v1.2/single/receivers/\(receiver)/staged", [
      "master_enable": true,
      "activation": ["mode": "activate_scheduled_absolute", "requested_time": "1000000:0"],
    ])
    XCTAssertEqual(result.status, .accepted)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(provider.activations.count, 1)
  }

  func testRequestedTimesThatCannotBeScheduledAreBadRequests() async throws {
    let path = "v1.2/single/receivers/\(receiver)/staged"
    let limit = NMOSConnectionAPI.maximumScheduleAhead
    let now = NMOSTimestamp.now()
    let beyond = NMOSTimestamp(seconds: now.seconds + limit + 60, nanoseconds: now.nanoseconds)
    // the largest numbers a client can write, and the first past what is accepted
    let refused: [(String, String)] = [
      ("activate_scheduled_relative", "9223372036854775807:0"),
      ("activate_scheduled_relative", "9223372036854775807:999999999"),
      ("activate_scheduled_relative", "9223372036854775808:0"),
      ("activate_scheduled_relative", "\(limit + 1):0"),
      ("activate_scheduled_relative", "0:1000000000"),
      ("activate_scheduled_relative", "0:99999999999999999999"),
      ("activate_scheduled_absolute", "9223372036854775807:0"),
      ("activate_scheduled_absolute", "18446744073709551616:0"),
      ("activate_scheduled_absolute", beyond.description),
    ]
    for (mode, time) in refused {
      let result = try await send(.PATCH, path, [
        "master_enable": true, "activation": ["mode": .string(mode), "requested_time": .string(time)],
      ])
      XCTAssertEqual(result.status, .badRequest, "\(mode) \(time)")
      XCTAssertEqual(result.json?["code"], 400, "\(mode) \(time)")
    }
    // none of them staged anything, scheduled anything or left the endpoint locked
    let staged = try await send(.GET, path)
    XCTAssertEqual(staged.json?["master_enable"], false)
    XCTAssertEqual(staged.json?["activation"], ["mode": .null, "requested_time": .null, "activation_time": .null])
    XCTAssertTrue(provider.activations.isEmpty)

    // the furthest that is accepted, which can then be cancelled
    let furthest = try await send(.PATCH, path, [
      "activation": ["mode": "activate_scheduled_relative", "requested_time": .string("\(limit):0")],
    ])
    XCTAssertEqual(furthest.status, .accepted)
    let cancelled = try await send(.PATCH, path, ["activation": ["mode": .null]])
    XCTAssertEqual(cancelled.status, .ok)

    // through the bulk interface each is refused singly, and nothing else is disturbed
    let bulk = try await send(.POST, "v1.2/bulk/receivers", [
      ["id": .string(receiver.description), "params": [
        "activation": ["mode": "activate_scheduled_relative", "requested_time": "9223372036854775807:0"],
      ]],
    ])
    XCTAssertEqual(bulk.json?.arrayValue?.first?["code"], 400)
  }

  // MARK: - Bulk

  func testBulkStagesEachEndpointAsItWouldAlone() async throws {
    let unknown = NMOSID(UUID())
    let result = try await send(.POST, "v1.2/bulk/receivers", [
      ["id": .string(receiver.description),
       "params": ["master_enable": true, "activation": ["mode": "activate_immediate"]]],
      ["id": .string(danteReceiver.description),
       "params": ["activation": ["mode": "activate_scheduled_relative", "requested_time": "3600:0"]]],
      ["id": .string(receiver.description), "params": ["transport_params": [["frc_enabled": true]]]],
      ["id": .string(unknown.description), "params": ["master_enable": true]],
    ])
    XCTAssertEqual(result.status, .ok)
    let results = try XCTUnwrap(result.json?.arrayValue)
    XCTAssertEqual(results.map { $0["id"] }, [
      .string(receiver.description), .string(danteReceiver.description),
      .string(receiver.description), .string(unknown.description),
    ])
    XCTAssertEqual(results.map { $0["code"] }, [200, 202, 400, 404])
    XCTAssertNil(results[0]["error"])
    XCTAssertEqual(results[2]["error"], "Un-recognised parameter 'frc_enabled'")
    XCTAssertEqual(results[2]["debug"], .null)
    XCTAssertEqual(provider.activations.count, 1)

    // through v1.1 the vendor transport is a conflict, as it would be singly
    let older = try await send(.POST, "v1.1/bulk/receivers", [
      ["id": .string(danteReceiver.description), "params": ["activation": ["mode": .null]]],
    ])
    XCTAssertEqual(older.json?.arrayValue?.first?["code"], 409)
  }

  func testBulkRequestsThatDoNotMeetTheSchemaAreRefusedWhole() async throws {
    for body: NMOSJSONValue in [
      ["id": .string(receiver.description)],
      [["id": .string(receiver.description)]],
      [["id": "not-a-uuid", "params": [:]]],
      [["id": .string(receiver.description), "params": [:], "extra": 1]],
    ] {
      let result = try await send(.POST, "v1.2/bulk/receivers", body)
      XCTAssertEqual(result.status, .badRequest, "\(body)")
    }
    // senders are not receivers
    let wrongKind = try await send(.POST, "v1.2/bulk/senders", [
      ["id": .string(receiver.description), "params": ["master_enable": true]],
    ])
    XCTAssertEqual(wrongKind.json?.arrayValue?.first?["code"], 404)
  }

  // MARK: - Changes made elsewhere

  func testAResourceDescribedLaterIsGivenItsSubscription() async throws {
    // the receiver is connected through the API before IS-04 has a resource for it
    let path = "v1.2/single/receivers/\(danteReceiver)/staged"
    let patched = try await send(.PATCH, path, [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
    ])
    XCTAssertEqual(patched.status, .ok)
    let absent = await store.resource(.receiver, id: danteReceiver)
    XCTAssertNil(absent)

    // whatever describes the device does not know what the receiver is connected to
    await store.upsert(.receiver(.init(
      id: danteReceiver, label: "Dante Rx", description: "", deviceID: device,
      transport: "urn:x-nmos:transport:dante", interfaceBindings: [], subscription: .init(active: false)
    )))
    for _ in 0..<200 {
      if await store.receivers.first(where: { $0.id == danteReceiver })?.subscription.active == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let described = await store.receivers.first { $0.id == danteReceiver }
    XCTAssertEqual(described?.subscription, .init(senderID: peer, active: true))
  }

  func testChangesMadeElsewhereReachActiveStagedAndIS04() async throws {
    // connected through the API first, so that there is a peer to forget
    _ = try await send(.PATCH, "v1.2/single/receivers/\(receiver)/staged", [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
    ])
    let before = await receiverSubscription()
    XCTAssertEqual(before?.0.senderID, peer)

    var elsewhere = Self.receiverParameters
    elsewhere["multicast_ip"] = "239.1.2.3"
    provider.changeExternally(receiver, to: .init(masterEnable: true, transportParameters: [elsewhere]))
    try await waitForReceiverVersion(after: before?.1)

    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["transport_params"], [.object(elsewhere)])
    // whatever it is now connected to, it is not known to be the sender the client named
    XCTAssertEqual(active.json?["sender_id"], .null)
    let staged = try await send(.GET, "v1.2/single/receivers/\(receiver)/staged")
    XCTAssertEqual(staged.json?["transport_params"], [.object(elsewhere)])
    let after = await receiverSubscription()
    XCTAssertEqual(after?.0, .init(senderID: nil, active: true))
  }

  func testAProviderReportingTheAPIsOwnActivationDoesNotForgetThePeer() async throws {
    _ = try await send(.PATCH, "v1.2/single/receivers/\(receiver)/staged", [
      "sender_id": .string(peer.description), "master_enable": true,
      "transport_params": [["multicast_ip": "239.9.9.9", "destination_port": "auto"]],
      "activation": ["mode": "activate_immediate"],
    ])
    let before = await receiverSubscription()
    // the device settles on a port of its own choosing some time after the activation
    var settled = Self.receiverParameters
    settled["multicast_ip"] = "239.9.9.9"
    settled["destination_port"] = 5020
    provider.changeExternally(receiver, to: .init(masterEnable: true, transportParameters: [settled]))
    try await waitForReceiverVersion(after: before?.1)

    let active = try await send(.GET, "v1.2/single/receivers/\(receiver)/active")
    XCTAssertEqual(active.json?["sender_id"], .string(peer.description))
    XCTAssertEqual(active.json?["transport_params"]?.arrayValue?.first?["destination_port"], 5020)
    let staged = try await send(.GET, "v1.2/single/receivers/\(receiver)/staged")
    XCTAssertEqual(staged.json?["transport_params"]?.arrayValue?.first?["destination_port"], "auto")
  }

  func testASettingTheEndpointWritesDifferentlyIsStillTheOneActivated() async throws {
    provider.writesStringsInLowerCase = true
    await store.upsert(.receiver(.init(
      id: danteReceiver, label: "Dante Rx", description: "", deviceID: device,
      transport: "urn:x-nmos:transport:dante", interfaceBindings: [], subscription: .init(active: false)
    )))
    let path = "v1.2/single/receivers/\(danteReceiver)"
    let patched = try await send(.PATCH, "\(path)/staged", [
      "sender_id": .string(peer.description), "master_enable": true, "activation": ["mode": "activate_immediate"],
      "transport_params": [["device_name": "StageBox", "channel_name": "Kick"]],
    ])
    XCTAssertEqual(patched.status, .ok)

    // the endpoint reads back "stagebox", which is the setting the client made
    let active = try await send(.GET, "\(path)/active")
    XCTAssertEqual(active.json?["sender_id"], .string(peer.description))
    XCTAssertEqual(active.json?["master_enable"], true)

    // and it is still that setting when the endpoint next reports itself
    let before = await store.receivers.first { $0.id == danteReceiver }?.version
    provider.changeExternally(danteReceiver, to: .init(
      masterEnable: true,
      transportParameters: [["device_name": "stagebox", "channel_name": "kick", "latency": 2]]
    ))
    for _ in 0..<200 {
      if await store.receivers.first(where: { $0.id == danteReceiver })?.version != before { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let observed = await store.receivers.first { $0.id == danteReceiver }
    XCTAssertEqual(observed?.subscription, .init(senderID: peer, active: true))
    let later = try await send(.GET, "\(path)/active")
    XCTAssertEqual(later.json?["sender_id"], .string(peer.description))

    // a setting that really is different is one made elsewhere, by whoever made it
    provider.changeExternally(danteReceiver, to: .init(
      masterEnable: true, transportParameters: [["device_name": "console", "channel_name": "kick"]]
    ))
    for _ in 0..<200 {
      if await store.receivers.first(where: { $0.id == danteReceiver })?.subscription.senderID == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let changed = await store.receivers.first { $0.id == danteReceiver }
    XCTAssertEqual(changed?.subscription, .init(senderID: nil, active: true))
  }

  private func waitForReceiverVersion(after version: NMOSTimestamp?) async throws {
    for _ in 0..<200 {
      if await receiverSubscription()?.1 != version { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("the receiver's version did not change")
  }
}
