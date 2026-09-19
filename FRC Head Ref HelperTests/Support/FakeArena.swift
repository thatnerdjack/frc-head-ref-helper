//
//  FakeArena.swift
//  FRC Head Ref HelperTests
//
//  A websocket server on 127.0.0.1 that plays the part of Cheesy Arena.
//
//  Built on the legacy `NWListener` rather than iOS 26's `NetworkListener`,
//  which is the opposite of the choice made everywhere else in this project,
//  so it is worth saying why.
//
//  A websocket server has to answer the client's HTTP upgrade request, and the
//  hook for that is `NWProtocolWebSocket.Options.setClientRequestHandler` — it
//  is handed the client's subprotocols and headers and returns an accept or a
//  reject. The new `WebSocket` protocol builder exposes `additionalHeaders`,
//  `subprotocols` and `skipHandshake`, but nothing that answers an inbound
//  upgrade, and a `NetworkListener<WebSocket>` built without one never invokes
//  its accept handler at all: the TCP connection completes and is then reset,
//  which from the client's side looks exactly like ECONNRESET after the
//  handshake. That cost an afternoon, hence this comment.
//
//  The app itself is a websocket CLIENT and uses the modern API throughout.
//  This is test scaffolding for the one role the new API does not yet cover.
//

import Foundation
import Network

/// A loopback websocket server with a scripted response.
///
/// Not an actor: the accept handler has to be able to sit on a connection for
/// as long as a test wants without blocking reads of `connectionCount`, and
/// actor isolation would serialise exactly those against each other.
final class FakeArena: @unchecked Sendable {

    enum ArenaError: Error {
        /// The listener never reached `.ready`.
        case neverStarted
    }

    /// What the server does once a client is connected.
    enum Behaviour: Sendable {
        /// Send the scripted lines, then hold the connection open. The test
        /// decides when it dies.
        case holdOpen
        /// Send the scripted lines, then close cleanly — a field server
        /// restarting between matches.
        case hangUp
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeArena")
    private let script: [String]
    private let behaviour: Behaviour

    private let lock = NSLock()
    private var connections = 0
    private var live: [NWConnection] = []
    private var startResumed = false

    /// How many clients have been accepted. Two means the socket genuinely
    /// dialled again, rather than the first connection having survived.
    var connectionCount: Int { lock.withLock { connections } }

    init(script: [String], behaviour: Behaviour = .holdOpen) throws {
        self.script = script
        self.behaviour = behaviour

        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        // The piece the modern builder has no equivalent for. Without it the
        // upgrade is never answered and the connection is reset.
        options.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        // Port 0: the OS picks a free one, so parallel runs cannot collide.
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening and returns the URL to point a socket at.
    ///
    /// Waits for `.ready` rather than polling `port`, because the listener
    /// reports a port of 0 until it is actually bound and treating that as
    /// real is a silent way to spend ten seconds connecting to nothing.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // The state handler can fire more than once, and resuming a
            // continuation twice is a hard crash.
            @Sendable func finish(_ result: Result<URL, any Error>) {
                let alreadyResumed: Bool = self.lock.withLock {
                    defer { self.startResumed = true }
                    return self.startResumed
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue, port != 0 else {
                        finish(.failure(ArenaError.neverStarted))
                        return
                    }
                    finish(.success(URL(string: "ws://127.0.0.1:\(port)")!))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(ArenaError.neverStarted))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            connections += 1
            live.append(connection)
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.sendScript(over: connection)
        }
        connection.start(queue: queue)
    }

    private func sendScript(over connection: NWConnection) {
        for line in script {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text",
                                                      metadata: [metadata])
            connection.send(content: Data(line.utf8),
                            contentContext: context,
                            isComplete: true,
                            completion: .contentProcessed { _ in })
        }

        guard behaviour == .hangUp else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close",
                                                  metadata: [metadata])
        connection.send(content: nil,
                        contentContext: context,
                        isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Kills the server and every connection it is holding.
    func stop() {
        let open: [NWConnection] = lock.withLock {
            let copy = live
            live = []
            return copy
        }
        for connection in open { connection.cancel() }
        listener.cancel()
    }
}

extension FakeArena.Behaviour: Equatable {}
