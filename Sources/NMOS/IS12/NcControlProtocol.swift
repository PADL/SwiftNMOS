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
import Logging
import Synchronization

/// The IS-12 control protocol: MS-05-02 method calls and events as JSON over a WebSocket.
public enum NcControlProtocol {
  public static let version = NMOSAPIVersion.v1_0
  /// Relative to `/x-nmos/`; a device advertises it in its IS-04 `controls`.
  public static let path = "ncp/\(version)"
  /// The control type a device's IS-04 `controls` entry for this endpoint carries.
  public static let controlType = "urn:x-nmos:control:ncp/\(version)"

  static func register(on router: NMOSRouter, model: any NcDeviceModel, logger: Logger) async {
    await router.add(.GET, path) { request in
      // a connection is a session of its own, known to the model by where it comes from
      let session = NcSession(peer: request.http.remoteAddress.map(NcSession.Peer.init))
      let connection = NcControlConnection(model: model, session: session, logger: logger)
      let handler = WebSocketHTTPHandler(handler: MessageFrameWSHandler(handler: connection))
      return try await handler.handleRequest(request.http)
    }
  }
}

extension NcSession.Peer {
  init(_ address: HTTPRequest.Address) {
    switch address {
    case let .ip4(address, port), let .ip6(address, port): self = .ip(address, port: port)
    case let .unix(path): self = .local(path)
    }
  }
}

/// One WebSocket connection of the control protocol: it carries a control session for
/// as long as it is open, and ends the session with the model when it closes.
struct NcControlConnection: WSMessageHandler {
  let model: any NcDeviceModel
  let session: NcSession
  let logger: Logger

  func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
    let (output, continuation) = AsyncStream<WSMessage>.makeStream()
    let control = NcControlSession(model: model, session: session, output: continuation)
    logger.debug("control session with \(session) opened")

    // the model's events for this session, of the objects it has subscribed to
    let notifications = model.notifications(for: session)
    let notifier = Task {
      for await notification in notifications where control.subscriptions.contains(notification.oid) {
        control.send(NcProtocolCodec.notification([notification]))
      }
    }
    Task { [model, session, logger] in
      receiving: for await message in client {
        switch message {
        case let .text(text): await control.receive(Data(text.utf8))
        case let .data(binary): await control.receive(binary)
        case .close: break receiving
        }
      }
      notifier.cancel()
      await model.sessionEnded(session)
      continuation.finish()
      logger.debug("control session with \(session) closed")
    }
    return output
  }
}

/// One controller's session: the commands it sends and the objects it subscribed to.
private final class NcControlSession: Sendable {
  private let model: any NcDeviceModel
  private let session: NcSession
  private let output: AsyncStream<WSMessage>.Continuation
  private let subscribed = Mutex(Set<NcOid>())

  init(model: any NcDeviceModel, session: NcSession, output: AsyncStream<WSMessage>.Continuation) {
    self.model = model
    self.session = session
    self.output = output
  }

  var subscriptions: Set<NcOid> { subscribed.withLock { $0 } }

  func send(_ message: NMOSJSONValue) {
    // a message is built from JSON values, so it cannot fail to encode
    guard let data = try? message.data() else { return }
    output.yield(.text(String(decoding: data, as: UTF8.self)))
  }

  /// Acts on a message from the controller and answers it.
  func receive(_ data: Data) async {
    let message: NcIncomingMessage
    do {
      message = try NcProtocolCodec.parse(data)
    } catch {
      send(NcProtocolCodec.error(error))
      return
    }

    switch message {
    case let .commands(commands):
      // in order, as a later command can depend on an earlier one's effect
      var responses = [(handle: Int64, result: NcMethodResult)]()
      for command in commands {
        let result: NcMethodResult = switch command.command {
        case let .success(command):
          await model.handleCommand(command, session: session)
        case let .failure(error):
          .error(error.status, error.message)
        }
        responses.append((command.handle, result))
      }
      send(NcProtocolCodec.commandResponse(responses))
    case let .subscription(oids):
      // a Subscription message states the whole set, replacing the one before
      let accepted = await model.subscribable(oids, session: session)
      let changed = subscribed.withLock { subscribed in
        let changed = subscribed != Set(accepted)
        subscribed = Set(accepted)
        return changed
      }
      if changed {
        await model.subscriptionsChanged(to: Set(accepted), session: session)
      }
      send(NcProtocolCodec.subscriptionResponse(accepted))
    }
  }
}
