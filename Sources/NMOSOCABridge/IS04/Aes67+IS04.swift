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
import SwiftOCA
import SwiftOCADevice

extension NMOSOcaRTPAdaptation: NMOSOcaResourceDescribing {
  /// A sender is multicast or unicast as its stream is; a receiver takes either, and
  /// IS-04 has it say so by giving the transport without a subclassification.
  public func transport(of endpoint: NMOSOcaEndpoint) async -> String {
    guard endpoint.isSender else { return NMOSOcaTransport.rtp }
    switch endpoint.endpoint.streamCastMode {
    case .multicast: return NMOSOcaTransport.rtpMulticast
    case .unicast: return NMOSOcaTransport.rtpUnicast
    case .none: break
    }
    // not every application gives the cast mode, but an AES67 one gives the destination
    guard let data = try? Aes67EndpointAdaptationData(blob: endpoint.endpoint.adaptationData),
          let destination = data.ipParameters.first?.destinationAddress, !destination.isEmpty
    else { return NMOSOcaTransport.rtp }
    return MediaStreamSDP.isMulticast(destination) ? NMOSOcaTransport.rtpMulticast : NMOSOcaTransport.rtpUnicast
  }

  /// The cast mode and the AES67 destination are the endpoint's.
  public var descriptionProperties: NMOSOcaObservedProperties {
    .of(SwiftOCADevice.OcaMediaTransportApplication.self, [.init(defLevel: 3, propertyIndex: 10): { $0.endpoints }])
  }

  /// IS-04 requires an RTP sender to give the location of its SDP file.
  public func hasTransportFile(_ endpoint: NMOSOcaEndpoint) async -> Bool {
    endpoint.isSender
  }
}
