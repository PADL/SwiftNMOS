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
@testable import NMOSDiscovery
import Synchronization
import XCTest

/// The browser without a responder: it is told what a browse finds, and its resolver
/// answers as the test decides.
final class NMOSOcaServiceBrowserTests: XCTestCase {
  /// A resolver that fails a given number of times before it succeeds, and then goes on
  /// answering as the test tells it to.
  private final class Resolver: Sendable {
    private struct State {
      var failures: Int
      var calls = 0
      var open = [AsyncStream<NMOSDiscoveredService>.Continuation]()
    }

    private let state: Mutex<State>

    init(failures: Int) { state = Mutex(State(failures: failures)) }

    var calls: Int { state.withLock { $0.calls } }

    private func service(_ name: String, txt: [String: String]) -> NMOSDiscoveredService {
      NMOSDiscoveredService(name: name, host: "192.0.2.7", port: 8010, txt: txt)
    }

    func resolve(_ event: NMOSOcaBrowseEvent) -> AsyncStream<NMOSDiscoveredService> {
      let (answers, continuation) = AsyncStream<NMOSDiscoveredService>.makeStream()
      state.withLock { state in
        state.calls += 1
        guard state.calls > state.failures else { return continuation.finish() }
        state.open.append(continuation)
        continuation.yield(service(event.name, txt: ["pri": "0"]))
      }
      return answers
    }

    func answer(_ name: String = "registry", txt: [String: String]) {
      let answer = service(name, txt: txt)
      state.withLock { state in
        for continuation in state.open {
          continuation.yield(answer)
        }
      }
    }

    /// Ends the resolutions there are, as a failure would.
    func fail() {
      state.withLock { state in
        for continuation in state.open {
          continuation.finish()
        }
        state.open.removeAll()
      }
    }
  }

  /// Collects what the browser reports, so a test can look without ending the stream.
  private final class Reports: Sendable {
    private final class Box: Sendable {
      let value = Mutex([[NMOSDiscoveredService]]())
    }

    private let reports = Box()
    private let task: Task<Void, Never>

    init(_ found: AsyncStream<[NMOSDiscoveredService]>) {
      task = Task { [reports] in
        for await services in found { reports.value.withLock { $0.append(services) } }
      }
    }

    deinit { task.cancel() }

    var all: [[NMOSDiscoveredService]] { reports.value.withLock { $0 } }

    /// Waits for the report after the first `count`, nil if none comes in time.
    func report(after count: Int) async -> [NMOSDiscoveredService]? {
      for _ in 0..<200 {
        if let report = reports.value.withLock({ $0.count > count ? $0[count] : nil }) { return report }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return nil
    }
  }

  private func makeBrowser(_ resolver: Resolver) -> (browser: NMOSOcaServiceBrowser, reports: Reports) {
    let (found, continuation) = AsyncStream<[NMOSDiscoveredService]>.makeStream()
    let browser = NMOSOcaServiceBrowser(
      continuation: continuation, resolveBackoff: .milliseconds(10)...(.milliseconds(40))
    ) { resolver.resolve($0) }
    return (browser, Reports(found))
  }

  private func event(_ name: String = "registry", isAdded: Bool = true, interface: UInt32 = 2) -> NMOSOcaBrowseEvent {
    NMOSOcaBrowseEvent(
      isAdded: isAdded, name: name, regType: "_nmos-register._tcp.", domain: "local.", interfaceIndex: interface
    )
  }

  func testAnInstanceThatDoesNotResolveAtFirstIsResolvedAgain() async throws {
    // a browse reports an instance once, so only the browser can try again
    let resolver = Resolver(failures: 2)
    let (browser, reports) = makeBrowser(resolver)
    await browser.handle(event())

    let services = await reports.report(after: 0)
    XCTAssertEqual(services?.map(\.name), ["registry"])
    XCTAssertEqual(services?.first?.host, "192.0.2.7")
    XCTAssertEqual(resolver.calls, 3)

    // once resolved it is left alone
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(resolver.calls, 3)
  }

  func testAnInstanceWhoseTXTRecordChangesIsReportedAgain() async throws {
    // to a browse nothing has happened: only what it resolves to says so
    let resolver = Resolver(failures: 0)
    let (browser, reports) = makeBrowser(resolver)
    await browser.handle(event())
    _ = await reports.report(after: 0)

    resolver.answer(txt: ["pri": "1"])
    let services = await reports.report(after: 1)
    XCTAssertEqual(services?.first?.txt, ["pri": "1"])
    XCTAssertEqual(resolver.calls, 1)
  }

  func testAnAnswerThatChangesNothingIsNotReported() async throws {
    // a responder answers once for each interface it has the service on
    let resolver = Resolver(failures: 0)
    let (browser, reports) = makeBrowser(resolver)
    await browser.handle(event())
    _ = await reports.report(after: 0)

    resolver.answer(txt: ["pri": "0"])
    resolver.answer(txt: ["pri": "0"])
    resolver.answer(txt: ["pri": "1"])
    let services = await reports.report(after: 1)
    XCTAssertEqual(services?.first?.txt, ["pri": "1"])
    XCTAssertEqual(reports.all.count, 2)
  }

  func testAResolutionThatEndsIsStartedAgainAndWhatItFoundStands() async throws {
    let resolver = Resolver(failures: 0)
    let (browser, reports) = makeBrowser(resolver)
    await browser.handle(event())
    _ = await reports.report(after: 0)

    resolver.fail()
    let deadline = ContinuousClock.now + .seconds(3)
    while resolver.calls < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(resolver.calls, 2)
    // the instance is still advertised, and answers as it did: there is nothing to report
    XCTAssertEqual(reports.all.count, 1)

    resolver.answer(txt: ["pri": "1"])
    let services = await reports.report(after: 1)
    XCTAssertEqual(services?.first?.txt, ["pri": "1"])
  }

  func testStopsListeningToAnInstanceThatIsWithdrawn() async throws {
    let resolver = Resolver(failures: 0)
    let (browser, reports) = makeBrowser(resolver)
    await browser.handle(event())
    _ = await reports.report(after: 0)

    await browser.handle(event(isAdded: false))
    let gone = await reports.report(after: 1)
    XCTAssertEqual(gone, [])
    resolver.answer(txt: ["pri": "1"])
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(reports.all.count, 2)
  }

  func testStopsResolvingAnInstanceThatIsWithdrawn() async throws {
    let resolver = Resolver(failures: .max)
    let (browser, reports) = makeBrowser(resolver)
    await browser.handle(event())
    // it is tried again, however long a busy machine takes to get round to it
    let deadline = ContinuousClock.now + .seconds(3)
    while resolver.calls < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertGreaterThan(resolver.calls, 1)

    await browser.handle(event(isAdded: false))
    try await Task.sleep(for: .milliseconds(60))
    let calls = resolver.calls
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(resolver.calls, calls)
    // it was never resolved, so there was never anything to report
    XCTAssertEqual(reports.all, [])
  }

  func testWaitsLongerBetweenAttemptsUpToALimit() async throws {
    // waits of 10, 20, 40, 40... ms: four attempts take at least the first three waits,
    // however slow or fast the machine is
    let resolver = Resolver(failures: .max)
    let (browser, _) = makeBrowser(resolver)
    let started = ContinuousClock.now
    await browser.handle(event())
    let deadline = started + .seconds(3)
    while resolver.calls < 4, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertGreaterThanOrEqual(resolver.calls, 4)
    XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(70))
    await browser.reset()
  }

  func testAnInstanceSeenOnASecondInterfaceIsResolvedOnce() async throws {
    let resolver = Resolver(failures: 0)
    let (browser, reports) = makeBrowser(resolver)
    await browser.handle(event(interface: 2))
    await browser.handle(event(interface: 3))
    let services = await reports.report(after: 0)
    XCTAssertEqual(services?.count, 1)
    XCTAssertEqual(resolver.calls, 1)

    // it is gone only when it has left every interface
    await browser.handle(event(isAdded: false, interface: 2))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(reports.all.count, 1)
    await browser.handle(event(isAdded: false, interface: 3))
    let gone = await reports.report(after: 1)
    XCTAssertEqual(gone, [])
  }
}
