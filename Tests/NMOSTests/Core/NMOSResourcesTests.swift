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
import XCTest

/// The models against the example documents of AMWA IS-04 v1.3 (Apache 2.0), and against
/// audio resources written to its schemas where the examples are video.
final class NMOSResourcesTests: XCTestCase {
  // decoding then encoding must give back the same JSON, member for member
  private func assertRoundTrips<T: Codable>(
    _ type: T.Type,
    _ text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let original = try NMOSJSONValue(data: Data(text.utf8))
    let decoded = try JSONDecoder().decode(type, from: Data(text.utf8))
    XCTAssertEqual(try NMOSJSONValue(encoding: decoded), original, file: file, line: line)
  }

  func testNodeExample() throws {
    try assertRoundTrips(NMOSNodeResource.self, """
    {"version":"1441700172:318426300","hostname":"host1","caps":{},"href":"http://172.29.80.65:12345/",
     "api":{"versions":["v1.0","v1.1","v1.2","v1.3"],"endpoints":[
       {"host":"172.29.80.65","port":12345,"protocol":"http"},
       {"host":"172.29.80.65","port":443,"protocol":"https","authorization":false}]},
     "services":[{"href":"https://172.29.80.65:443/x-manufacturer/status/","authorization":false,
       "type":"urn:x-manufacturer:service:status"}],
     "label":"host1","description":"host1","tags":{},"id":"3b8be755-08ff-452b-b217-c9151eb21193",
     "clocks":[{"name":"clk0","ref_type":"internal"},
       {"name":"clk1","ref_type":"ptp","traceable":true,"version":"IEEE1588-2008",
        "gmid":"08-00-11-ff-fe-21-e1-b0","locked":true}],
     "interfaces":[{"name":"eth0","chassis_id":"74-26-96-db-87-31","port_id":"74-26-96-db-87-31",
       "attached_network_device":{"chassis_id":"2f-8c-af-79-c7-00","port_id":"Ethernet 1/3"}},
       {"name":"eth1","chassis_id":null,"port_id":"74-26-96-db-87-32"}]}
    """)
  }

  func testDeviceExample() throws {
    try assertRoundTrips(NMOSDeviceResource.self, """
    {"receivers":[],"label":"pipeline 1 default device","description":"pipeline 1 default device",
     "tags":{},"version":"1441703338:962976113","id":"67c25159-ce25-4000-a66c-f31fff890265",
     "type":"urn:x-nmos:device:pipeline","senders":[],"node_id":"3b8be755-08ff-452b-b217-c9151eb21193",
     "controls":[{"type":"urn:x-manufacturer:control:generic","href":"ws://182.54.54.75:223"},
       {"type":"urn:x-nmos:control:sr-ctrl/v1.1","href":"http://134.24.64.22/x-nmos/connection/v1.1/"}]}
    """)
  }

  func testSenderExample() throws {
    try assertRoundTrips(NMOSSenderResource.self, """
    {"description":"Test Card","label":"Test Card","version":"1441704616:890020555",
     "manifest_href":"http://172.29.80.65/x-manufacturer/senders/d7aa5a30-681d-4e72-92fb-f0ba0f6f4c3e/stream.sdp",
     "flow_id":"5fbec3b1-1b0f-417d-9059-8b94a47197ed","id":"d7aa5a30-681d-4e72-92fb-f0ba0f6f4c3e",
     "transport":"urn:x-nmos:transport:rtp.mcast","device_id":"9126cc2f-4c26-4c9b-a6cd-93c4381c9be5",
     "interface_bindings":["eth0","eth1"],"caps":{},"tags":{},
     "subscription":{"receiver_id":null,"active":true}}
    """)
  }

  func testReceiverExample() throws {
    try assertRoundTrips(NMOSReceiverResource.self, """
    {"description":"","format":"urn:x-nmos:format:audio","tags":{"grouphint":["rx:audio"]},
     "caps":{"media_types":["audio/L24","audio/L16"]},
     "subscription":{"sender_id":"2683ad14-642f-459d-a169-ef91c76cec6b","active":true},
     "version":"1441704532:450093308","label":"RTPRx","id":"1eb53d65-ac83-441c-86f6-9b27df30ef0c",
     "transport":"urn:x-nmos:transport:rtp","interface_bindings":["eth0","eth1"],
     "device_id":"05017e08-b329-45f9-a566-a3f99cc11e4d"}
    """)
  }

  func testAudioSourceAndFlow() throws {
    try assertRoundTrips(NMOSSourceResource.self, """
    {"description":"Monitor mix","tags":{},"format":"urn:x-nmos:format:audio","caps":{},
     "version":"1441703336:902850419","parents":[],"label":"Mix","id":"4569cea2-ab63-4f97-8dd1-bad4669ea5e4",
     "device_id":"9126cc2f-4c26-4c9b-a6cd-93c4381c9be5","clock_name":"clk1",
     "channels":[{"label":"Left","symbol":"L"},{"label":"Right","symbol":"R"},{"label":"Aux"}]}
    """)
    try assertRoundTrips(NMOSFlowResource.self, """
    {"description":"Monitor mix","tags":{},"format":"urn:x-nmos:format:audio","label":"Mix",
     "version":"1441704616:587121295","parents":[],"source_id":"4569cea2-ab63-4f97-8dd1-bad4669ea5e4",
     "device_id":"9126cc2f-4c26-4c9b-a6cd-93c4381c9be5","id":"5fbec3b1-1b0f-417d-9059-8b94a47197ed",
     "media_type":"audio/L24","bit_depth":24,"sample_rate":{"numerator":48000,"denominator":1}}
    """)
  }

  // the schemas require these members even when there is no value to give
  func testRequiredMembersWithoutAValueAreWrittenAsNull() throws {
    let device = NMOSID(UUID())
    let sender = NMOSSenderResource(
      id: NMOSID(UUID()), label: "", description: "", flowID: nil, transport: "urn:x-nmos:transport:dante",
      deviceID: device, manifestHref: nil, interfaceBindings: [], subscription: .init(active: false)
    )
    let json = try NMOSJSONValue(encoding: sender)
    XCTAssertEqual(json["flow_id"], .null)
    XCTAssertEqual(json["manifest_href"], .null)
    XCTAssertEqual(json["subscription"], ["receiver_id": .null, "active": false])
    XCTAssertNil(json["caps"])

    let source = NMOSSourceResource(
      id: NMOSID(UUID()), label: "", description: "", deviceID: device, clockName: nil, channels: []
    )
    XCTAssertEqual(try NMOSJSONValue(encoding: source)["clock_name"], .null)
  }

  func testAnyResourceEncodesAsTheResourceItself() throws {
    let node = NMOSNodeResource(
      id: NMOSID(UUID()), label: "n", description: "d", href: "http://10.0.0.1/",
      api: .init(versions: [.v1_3], endpoints: [.init(host: "10.0.0.1", port: 80)])
    )
    var resource = NMOSResource.node(node)
    XCTAssertEqual(resource.kind, .node)
    XCTAssertEqual(resource.id, node.id)
    resource.version = NMOSTimestamp(seconds: 5)
    let json = try NMOSJSONValue(encoding: resource)
    XCTAssertEqual(json["version"], "5:0")
    XCTAssertEqual(json["api"]?["versions"], ["v1.3"])
    XCTAssertEqual(json["caps"], [:])
  }

  func testCollections() {
    XCTAssertEqual(NMOSResourceKind.node.collection, "self")
    XCTAssertEqual(NMOSResourceKind.sender.collection, "senders")
    XCTAssertEqual(NMOSResourceKind.registrationOrder.first, .node)
  }
}
