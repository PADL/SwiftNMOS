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

final class NMOSResourceStoreTests: XCTestCase {
  private let deviceID = NMOSID(UUID())

  private func receiver(_ label: String, id: NMOSID = NMOSID(UUID())) -> NMOSResource {
    .receiver(NMOSReceiverResource(
      id: id, label: label, description: "", deviceID: deviceID, transport: "urn:x-nmos:transport:rtp",
      interfaceBindings: ["eth0"], subscription: .init(active: false)
    ))
  }

  func testVersionChangesOnlyWhenContentDoes() async {
    // a clock that never advances, so ordering has to come from the store
    let store = NMOSResourceStore(now: { NMOSTimestamp(seconds: 100) })
    let id = NMOSID(UUID())

    let first = await store.upsert(receiver("a", id: id))
    XCTAssertEqual(first, NMOSTimestamp(seconds: 100))
    let unchanged = await store.upsert(receiver("a", id: id))
    XCTAssertEqual(unchanged, first)
    let changed = await store.upsert(receiver("b", id: id))
    XCTAssertGreaterThan(changed, first)
    let stored = await store.resource(.receiver, id: id)
    XCTAssertEqual(stored?.version, changed)
  }

  func testTouchGivesANewVersion() async {
    let store = NMOSResourceStore()
    let id = NMOSID(UUID())
    let first = await store.upsert(receiver("a", id: id))
    let touched = await store.touch(.receiver, id: id)
    XCTAssertGreaterThan(try XCTUnwrap(touched), first)
    let missing = await store.touch(.receiver, id: NMOSID(UUID()))
    XCTAssertNil(missing)
  }

  func testReconcileRemovesWhatIsNoLongerDescribed() async {
    let store = NMOSResourceStore()
    let kept = NMOSID(UUID()), dropped = NMOSID(UUID()), added = NMOSID(UUID())
    await store.upsert(receiver("kept", id: kept))
    await store.upsert(receiver("dropped", id: dropped))

    await store.reconcile([receiver("kept", id: kept), receiver("added", id: added)], replacing: [.receiver])
    let ids = await Set(store.receivers.map(\.id))
    XCTAssertEqual(ids, [kept, added])
  }

  func testListsInIDOrder() async {
    let store = NMOSResourceStore()
    for _ in 0..<8 { await store.upsert(receiver("r")) }
    let ids = await store.resources(.receiver).map(\.id)
    XCTAssertEqual(ids, ids.sorted())
  }

  func testReportsChanges() async {
    let store = NMOSResourceStore()
    let changes = await store.changes()
    let id = NMOSID(UUID())
    await store.upsert(receiver("a", id: id))
    await store.upsert(receiver("a", id: id))
    await store.upsert(receiver("b", id: id))
    await store.remove(.receiver, id: id)

    var seen = [NMOSResourceChange.Change]()
    for await change in changes {
      XCTAssertEqual(change.id, id)
      seen.append(change.change)
      if change.change == .removed { break }
    }
    // the unchanged upsert is not a change
    XCTAssertEqual(seen, [.added, .modified, .removed])
  }

  func testASubscriptionIsSetInOneStepAndNamesAPeerOnlyWhileActive() async {
    let store = NMOSResourceStore()
    let id = NMOSID(UUID()), device = NMOSID(UUID()), peer = NMOSID(UUID())
    let receiver = NMOSReceiverResource(
      id: id, label: "Rx", description: "", deviceID: device, transport: "urn:x-nmos:transport:rtp",
      interfaceBindings: [], subscription: .init(active: false)
    )
    let created = await store.upsert(.receiver(receiver))

    let connected = await store.setSubscription(.receiver, id: id, active: true, peer: peer)
    XCTAssertGreaterThan(try XCTUnwrap(connected), created)
    var stored = await store.receivers.first
    XCTAssertEqual(stored?.subscription, .init(senderID: peer, active: true))

    // the same again changes nothing, unless a new version is asked for
    let same = await store.setSubscription(.receiver, id: id, active: true, peer: peer)
    XCTAssertEqual(same, connected)
    let touched = await store.setSubscription(.receiver, id: id, active: true, peer: peer, touch: true)
    XCTAssertGreaterThan(try XCTUnwrap(touched), try XCTUnwrap(connected))

    await store.setSubscription(.receiver, id: id, active: false, peer: peer)
    stored = await store.receivers.first
    XCTAssertEqual(stored?.subscription, .init(senderID: nil, active: false))

    // only senders and receivers have one
    let missing = await store.setSubscription(.sender, id: id, active: true, peer: nil)
    XCTAssertNil(missing)
  }

  func testAnUpsertKeepsAManagedSubscription() async {
    let store = NMOSResourceStore()
    let id = NMOSID(UUID()), device = NMOSID(UUID()), peer = NMOSID(UUID())
    var sender = NMOSSenderResource(
      id: id, label: "Tx", description: "", flowID: nil, transport: "urn:x-nmos:transport:rtp",
      deviceID: device, manifestHref: nil, interfaceBindings: [], subscription: .init(active: false)
    )
    await store.upsert(.sender(sender))

    // until subscriptions are managed, whoever describes the resource writes all of it
    sender.subscription = .init(active: true)
    await store.upsert(.sender(sender))
    var stored = await store.senders.first
    XCTAssertEqual(stored?.subscription, .init(active: true))

    await store.manageSubscriptions()
    await store.setSubscription(.sender, id: id, active: true, peer: peer)
    let version = await store.senders.first?.version

    // a description read before the connection was made does not write over it
    sender.subscription = .init(active: false)
    await store.upsert(.sender(sender))
    stored = await store.senders.first
    XCTAssertEqual(stored?.subscription, .init(receiverID: peer, active: true))
    XCTAssertEqual(stored?.version, version)

    // the rest of the description still changes, and reconciling does as upserting does
    sender.label = "Program"
    await store.reconcile([.sender(sender)], replacing: [.sender])
    stored = await store.senders.first
    XCTAssertEqual(stored?.label, "Program")
    XCTAssertEqual(stored?.subscription, .init(receiverID: peer, active: true))
  }
}
