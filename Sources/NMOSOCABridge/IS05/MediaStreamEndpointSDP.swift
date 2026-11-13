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

/// Session descriptions of an application's stream endpoints. AES70-21 gives the AES67
/// application ConfigureEndpointFromSDP and an ActiveSDP field; AES70-23 gives Dante
/// neither, so this protocol is how a bridge such as NMOS patches either transport by
/// exchanging descriptions with whichever application the operation mode instantiated.
@OcaDevice
public protocol MediaStreamEndpointSDPRepresentable: SwiftOCADevice.OcaMediaTransportApplication {
  /// The description of the stream the endpoint sends or receives, empty when it carries
  /// no stream; an input configured but not started receives none.
  func getActiveSDP(_ id: OcaMediaStreamEndpointID) async throws -> OcaSDPString

  /// Configures an input endpoint from the media description of the description that
  /// `mediaIDType` and `mediaID` select (`MediaStreamSDP.selectStream`) and leaves it Ready,
  /// not started, as AES70-21 §10.2.4 has ConfigureEndpointFromSDP do: ApplyEndpointCommand
  /// Start starts it. An empty description closes any connection (NotReady).
  func configureEndpointFromSDP(
    endpointID: OcaMediaStreamEndpointID,
    sdpString: OcaSDPString,
    mediaIDType: Aes67MediaIDType,
    mediaID: OcaString,
    from controller: any OcaController
  ) async throws

  /// Whether the endpoint is patched by exchanging descriptions. An application with a
  /// native transport of its own answers per endpoint, as Dante does in AES67 mode.
  func usesSessionDescription(_ id: OcaMediaStreamEndpointID) async -> Bool
}

public extension MediaStreamEndpointSDPRepresentable {
  func usesSessionDescription(_ id: OcaMediaStreamEndpointID) async -> Bool { true }
}
