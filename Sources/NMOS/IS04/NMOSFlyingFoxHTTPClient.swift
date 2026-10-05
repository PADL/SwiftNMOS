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
import FlyingSocks
import Foundation
import Synchronization

public enum NMOSHTTPClientError: Error, Sendable, Equatable {
  /// Only plain `http` URLs with a host can be requested.
  case unsupportedURL(URL)
  case unresolvedHost(String)
  case timedOut
}

/// Plain HTTP requests through FlyingFox, one connection per request. That is all a node
/// needs of a Registration API, and it adds no dependency the HTTP server does not have.
public struct NMOSFlyingFoxHTTPClient: NMOSHTTPClient {
  /// How long a whole request may take. A heartbeat that takes longer than the heartbeat
  /// interval is as good as lost, so the node passes that interval.
  public var timeout: Duration
  private let lookup: Lookup

  /// Finds the addresses of a named host, in the order to try them, and may block while
  /// it does.
  typealias Lookup = @Sendable (_ host: String, _ port: UInt16) throws -> [Address]

  public init(timeout: Duration = .seconds(5)) {
    self.init(timeout: timeout, lookup: Self.systemLookup)
  }

  init(timeout: Duration, lookup: @escaping Lookup) {
    self.timeout = timeout
    self.lookup = lookup
  }

  public func send(_ method: HTTPMethod, _ url: URL, body: Data?) async throws -> NMOSHTTPClientResponse {
    guard url.scheme == "http", let host = url.host, !host.isEmpty else {
      throw NMOSHTTPClientError.unsupportedURL(url)
    }
    guard let port = UInt16(exactly: url.port ?? 80) else {
      throw NMOSHTTPClientError.unsupportedURL(url)
    }
    var headers: HTTPHeaders = [
      .host: port == 80 ? host : "\(host):\(port)",
      HTTPHeader("Accept"): "application/json",
      HTTPHeader("Connection"): "close",
    ]
    if body != nil { headers[.contentType] = "application/json" }
    let request = HTTPRequest(
      method: method, version: .http11, path: url.path.isEmpty ? "/" : url.path, query: [],
      headers: headers, body: HTTPBodySequence(data: body ?? Data())
    )
    let timeout = timeout
    let lookup = lookup

    return try await withThrowingTaskGroup(of: NMOSHTTPClientResponse.self) { group in
      group.addTask {
        // inside the timeout: a name that does not resolve must not outlast the request
        let addresses = try await Self.resolve(host: host, port: port, lookup: lookup)
        let response = try await Self.send(request, toFirstOf: addresses)
        var headers = [String: String]()
        for header in response.headers {
          headers[header.key.rawValue.lowercased()] = header.value
        }
        return try await NMOSHTTPClientResponse(
          status: Int(response.statusCode.code), body: response.bodyData, headers: headers
        )
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw NMOSHTTPClientError.timedOut
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  enum Address: Sendable {
    case ip4(sockaddr_in)
    case ip6(sockaddr_in6)
  }

  /// Tries each address in turn, as a name may resolve to an address the server is not
  /// listening on (IPv6 before IPv4, say). A node's requests are all safe to repeat.
  private static func send(_ request: HTTPRequest, toFirstOf addresses: [Address]) async throws -> HTTPResponse {
    var failure: (any Error)?
    for address in addresses {
      try Task.checkCancellation()
      var client = HTTPClient()
      do {
        switch address {
        case let .ip4(address): return try await client.sendHTTPRequest(request, to: address)
        case let .ip6(address): return try await client.sendHTTPRequest(request, to: address)
        }
      } catch {
        failure = error
      }
    }
    throw failure ?? CancellationError()
  }

  /// An address literal is used as it is. A name is looked up on a thread of its own,
  /// as the lookup blocks and must not hold one of the threads that run tasks; if the
  /// task is cancelled first, the lookup is left to finish and its answer is dropped.
  private static func resolve(host: String, port: UInt16, lookup: @escaping Lookup) async throws -> [Address] {
    if let address = try? sockaddr_in.inet(ip4: host, port: port) { return [.ip4(address)] }
    let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if let address = try? sockaddr_in6.inet6(ip6: literal, port: port) { return [.ip6(address)] }

    let pending = PendingLookup()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard pending.await(continuation) else { return }
        Thread.detachNewThread {
          pending.finish(Result { try lookup(host, port) })
        }
      }
    } onCancel: {
      pending.finish(.failure(CancellationError()))
    }
  }

  private static let systemLookup: Lookup = { host, port in
    // stream sockets only, so each address is listed once
    var hints = addrinfo()
    #if canImport(Glibc)
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #else
    hints.ai_socktype = SOCK_STREAM
    #endif
    var results: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &results) == 0 else {
      throw NMOSHTTPClientError.unresolvedHost(host)
    }
    defer { freeaddrinfo(results) }

    var addresses = [Address]()
    var cursor = results
    while let info = cursor?.pointee {
      cursor = info.ai_next
      guard let address = info.ai_addr else { continue }
      if info.ai_family == AF_INET {
        addresses.append(.ip4(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }))
      } else if info.ai_family == AF_INET6 {
        addresses.append(.ip6(address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }))
      }
    }
    guard !addresses.isEmpty else { throw NMOSHTTPClientError.unresolvedHost(host) }
    return addresses
  }
}

/// A lookup under way on another thread, awaited by a task that may stop waiting. The
/// first of the lookup's answer and the task's cancellation is what the task is given.
private final class PendingLookup: Sendable {
  private enum State {
    case idle
    case awaited(CheckedContinuation<[NMOSFlyingFoxHTTPClient.Address], any Error>)
    case finished
  }

  private let state = Mutex(State.idle)

  /// False if the wait is already over, in which case the continuation has been resumed.
  func await(_ continuation: CheckedContinuation<[NMOSFlyingFoxHTTPClient.Address], any Error>) -> Bool {
    let isAwaited = state.withLock { state in
      guard case .idle = state else { return false }
      state = .awaited(continuation)
      return true
    }
    if !isAwaited { continuation.resume(throwing: CancellationError()) }
    return isAwaited
  }

  func finish(_ result: Result<[NMOSFlyingFoxHTTPClient.Address], any Error>) {
    let continuation: CheckedContinuation<[NMOSFlyingFoxHTTPClient.Address], any Error>? = state.withLock { state in
      defer { state = .finished }
      if case let .awaited(continuation) = state { return continuation }
      return nil
    }
    continuation?.resume(with: result)
  }
}
