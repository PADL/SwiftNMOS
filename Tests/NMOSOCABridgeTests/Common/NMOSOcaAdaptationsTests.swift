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
import NMOSOCABridge
import SwiftOCA
import SwiftOCADevice
import XCTest

/// A Dante application that describes its even-numbered endpoints as SDP.
private final class PartlyDescribedApplication: SwiftOCADevice.DanteOcaMediaTransportApplication,
  MediaStreamEndpointSDPRepresentable
{
  func getActiveSDP(_ id: OcaMediaStreamEndpointID) async throws -> OcaSDPString { "" }

  func configureEndpointFromSDP(
    endpointID id: OcaMediaStreamEndpointID,
    sdpString: OcaSDPString,
    streamID: OcaUint16,
    from controller: any OcaController
  ) async throws {}

  func usesSessionDescription(_ id: OcaMediaStreamEndpointID) async -> Bool { id % 2 == 0 }
}

final class NMOSOcaAdaptationsTests: XCTestCase {
  @OcaDevice
  private func endpoint(
    _ application: SwiftOCADevice.OcaMediaTransportApplication,
    id: OcaMediaStreamEndpointID = 1
  ) -> NMOSOcaEndpoint {
    NMOSOcaEndpoint(
      application: application,
      endpoint: OcaMediaStreamEndpoint(idInternal: id, direction: .input),
      status: nil
    )
  }

  @OcaDevice
  private func role(_ name: String) -> String { "\(name)-\(UUID().uuidString)" }

  @OcaDevice
  func testEachTransportIsClaimedByItsAdaptation() async throws {
    _ = try await TestDevice.networkManager()
    let adaptations = NMOSOcaAdaptations.standard
    let aes67 = try await SwiftOCADevice.Aes67OcaMediaTransportApplication(
      role: role("Aes67"), deviceDelegate: OcaDevice.shared
    )
    let dante = try await SwiftOCADevice.DanteOcaMediaTransportApplication(
      role: role("Dante"), deviceDelegate: OcaDevice.shared
    )
    let milan = try await TestDevice.makeApplication("Milan")
    milan.adaptationIdentifier = MilanAdaptation.identifier
    let unknown = try await TestDevice.makeApplication("Unknown")

    let claimedAes67 = await adaptations.adaptation(for: endpoint(aes67))
    XCTAssertTrue(claimedAes67 is NMOSOcaRTPAdaptation)
    let claimedDante = await adaptations.adaptation(for: endpoint(dante))
    XCTAssertTrue(claimedDante is NMOSOcaDanteAdaptation)
    let claimedMilan = await adaptations.adaptation(for: endpoint(milan))
    XCTAssertTrue(claimedMilan is NMOSOcaMilanAdaptation)
    let claimedUnknown = await adaptations.adaptation(for: endpoint(unknown))
    XCTAssertNil(claimedUnknown)

    // a Milan entity's clock reference streams are endpoints too, but not audio
    let clockReference = NMOSOcaEndpoint(
      application: milan,
      endpoint: OcaMediaStreamEndpoint(
        idInternal: 1001, direction: .output,
        currentStreamMode: OcaMediaStreamMode(
          frameFormat: .crf_milan, encodingType: "", samplingRate: 48000, channelCount: 0, packetTime: 125e-6
        )
      ),
      status: nil
    )
    let claimedClockReference = await adaptations.adaptation(for: clockReference)
    XCTAssertNil(claimedClockReference)
  }

  @OcaDevice
  func testAnEndpointDescribedAsSDPIsClaimedAsRTP() async throws {
    _ = try await TestDevice.networkManager()
    let adaptations = NMOSOcaAdaptations.standard
    let application = try await PartlyDescribedApplication(
      role: role("DanteAes67"), deviceDelegate: OcaDevice.shared
    )
    let described = await adaptations.adaptation(for: endpoint(application, id: 2))
    XCTAssertTrue(described is NMOSOcaRTPAdaptation)
    let native = await adaptations.adaptation(for: endpoint(application, id: 1))
    XCTAssertTrue(native is NMOSOcaDanteAdaptation)
  }
}
