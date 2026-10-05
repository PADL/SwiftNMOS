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

import NMOS
import NMOSOCABridge
import XCTest

final class NMOSOcaTransportTests: XCTestCase {
  func testBaseRemovesTheSubclassification() {
    XCTAssertEqual(NMOSOcaTransport.base(of: NMOSOcaTransport.rtpMulticast), NMOSOcaTransport.rtp)
    XCTAssertEqual(NMOSOcaTransport.base(of: NMOSOcaTransport.rtp), NMOSOcaTransport.rtp)
    XCTAssertEqual(NMOSOcaTransport.base(of: NMOSOcaTransport.dante), NMOSOcaTransport.dante)
  }

  // Dante and Milan are named in the transport namespace, but IS-05 v1.1 knows neither,
  // so its version of the API does not serve them
  func testDanteAndMilanAreInTheTransportNamespaceAndServedFromV1_2() {
    for transport in [NMOSOcaTransport.dante, NMOSOcaTransport.milan] {
      XCTAssertTrue(transport.hasPrefix("urn:x-nmos:transport:"))
      XCTAssertEqual(NMOSConnectionAPI.earliestVersion(serving: transport), .v1_2)
    }
    XCTAssertEqual(NMOSConnectionAPI.earliestVersion(serving: NMOSOcaTransport.rtp), .v1_1)
  }
}
