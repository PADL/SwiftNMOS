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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NMOSClientError: Error, Sendable, Equatable {
  /// The API answered with a status that isn't success.
  case status(Int, String)
  case invalidResponse
}

/// What happened to a resource, as a Query API subscription reports it.
public enum NMOSResourceChange<Resource: Sendable>: Sendable {
  case updated(Resource)
  case removed(NMOSID)
}

/// An IS-04 Query API. A resource this library has no representation for, such as a video
/// receiver, is left out rather than failing what it was read with.
public struct NMOSQueryClient: Sendable {
  public static let apiVersion = "v1.3"

  /// Reads messages from a WebSocket until it closes.
  public typealias WebSocketConnector = @Sendable (URL) -> AsyncThrowingStream<Data, Error>

  private static let pageLimit = 500
  private static let maximumUpdateRate = 100

  /// The API's root, as `http://registry:8010`.
  public let baseURL: URL
  private let http: any NMOSHTTPClient
  private let connect: WebSocketConnector

  public init(
    baseURL: URL,
    http: any NMOSHTTPClient = NMOSFlyingFoxHTTPClient(),
    connect: @escaping WebSocketConnector = NMOSQueryClient.webSocket
  ) {
    self.baseURL = baseURL
    self.http = http
    self.connect = connect
  }

  private var apiURL: URL {
    baseURL.appending(path: "x-nmos/query/\(Self.apiVersion)")
  }

  private static func path(_ kind: NMOSResourceKind) -> String { "\(kind.rawValue)s" }

  struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
      value = try? decoder.singleValueContainer().decode(Value.self)
    }
  }

  /// Everything of a kind the API holds. Pages run from the newest back, so this follows
  /// `prev` to the end.
  public func resources<Resource: NMOSResourceRepresentable>(
    _ type: Resource.Type = Resource.self
  ) async throws -> [Resource] {
    var components = URLComponents(
      url: apiURL.appending(path: Self.path(Resource.kind)),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "paging.limit", value: "\(Self.pageLimit)")]
    var next = components.url
    var resources = [NMOSID: Resource]()
    while let url = next {
      let response = try await http.send(.GET, url, body: nil)
      guard response.status == 200 else {
        throw NMOSClientError.status(response.status, url.absoluteString)
      }
      let page = try JSONDecoder().decode([Lossy<Resource>].self, from: response.body)
      for resource in page.compactMap(\.value) {
        resources[resource.id] = resource
      }
      next = page.isEmpty ? nil : Self.link("prev", in: response.headers["link"])
    }
    return Array(resources.values)
  }

  /// The URL of the `rel` in a `Link` header.
  static func link(_ rel: String, in header: String?) -> URL? {
    for link in header?.split(separator: ",") ?? [] {
      let parts = link.split(separator: ";")
      guard parts.dropFirst().contains(where: {
        $0.trimmingCharacters(in: .whitespaces) == "rel=\"\(rel)\""
      }), let target = parts.first?.trimmingCharacters(in: .whitespaces),
      target.hasPrefix("<"), target.hasSuffix(">")
      else { continue }
      return URL(string: String(target.dropFirst().dropLast()))
    }
    return nil
  }

  private struct Subscription: Encodable {
    enum CodingKeys: String, CodingKey {
      case resourcePath = "resource_path"
      case maximumUpdateRate = "max_update_rate_ms"
      case persist, secure, params
    }

    let resourcePath: String
    let maximumUpdateRate: Int
    let persist = false
    let secure = false
    let params = [String: String]()
  }

  private struct SubscriptionResponse: Decodable {
    let href: String

    enum CodingKeys: String, CodingKey {
      case href = "ws_href"
    }
  }

  /// A Query API event: what's in one message of a subscription.
  struct Event<Resource: Decodable & Sendable>: Decodable, Sendable {
    struct Grain: Decodable, Sendable {
      struct Entry: Decodable, Sendable {
        let change: NMOSResourceChange<Resource>?

        private enum CodingKeys: String, CodingKey {
          case path, post
        }

        init(from decoder: any Decoder) throws {
          let container = try decoder.container(keyedBy: CodingKeys.self)
          if container.contains(.post) {
            change = (try? container.decode(Resource.self, forKey: .post)).map { .updated($0) }
          } else {
            change = .removed(try container.decode(NMOSID.self, forKey: .path))
          }
        }
      }

      let data: [Entry]
    }

    let grain: Grain
    var changes: [NMOSResourceChange<Resource>] { grain.data.compactMap(\.change) }
  }

  /// Follows a kind of resource: the first element is everything there is, each one after it
  /// what changed. The stream ends with an error when the connection is lost.
  public func changes<Resource: NMOSResourceRepresentable>(
    _ type: Resource.Type = Resource.self
  ) async throws -> AsyncThrowingStream<[NMOSResourceChange<Resource>], Error> {
    let body = try JSONEncoder().encode(Subscription(
      resourcePath: "/\(Self.path(Resource.kind))",
      maximumUpdateRate: Self.maximumUpdateRate
    ))
    let url = apiURL.appending(path: "subscriptions")
    let response = try await http.send(.POST, url, body: body)
    guard (200...201).contains(response.status) else {
      throw NMOSClientError.status(response.status, url.absoluteString)
    }
    let subscription = try JSONDecoder().decode(SubscriptionResponse.self, from: response.body)
    guard let socket = URL(string: subscription.href) else {
      throw NMOSClientError.invalidResponse
    }
    let messages = connect(socket)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await message in messages {
            let event = try JSONDecoder().decode(Event<Resource>.self, from: message)
            continuation.yield(event.changes)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Messages from `url`, through URLSession, which answers the server's pings.
  public static let webSocket: WebSocketConnector = { url in
    AsyncThrowingStream { continuation in
      let socket = URLSession.shared.webSocketTask(with: url)
      socket.resume()
      let reader = Task {
        do {
          while true {
            switch try await socket.receive() {
            case let .data(data): continuation.yield(data)
            case let .string(string): continuation.yield(Data(string.utf8))
            @unknown default: break
            }
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        reader.cancel()
        socket.cancel(with: .goingAway, reason: nil)
      }
    }
  }
}
