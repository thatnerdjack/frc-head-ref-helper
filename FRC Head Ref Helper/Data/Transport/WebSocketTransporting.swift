//
//  WebSocketTransporting.swift
//  FRC Head Ref Helper
//
//  A long-lived socket, abstracted so it can be replayed from a fixture.
//
//  Cheesy Arena pushes arena state over a websocket at ws://10.0.100.5:8080.
//  That connection is how the app knows a match just started, which is the
//  single most time-critical thing it displays.
//
//  Two protocols rather than one, because the lifetime of a *connection* is
//  not the lifetime of the *transport*: the transport is a factory that
//  outlives everything, and each connection is a disposable object with its
//  own frame stream. ReconnectingSocket throws away a connection and asks for
//  another; if frames came off the transport itself, frames from a dead
//  connection could interleave with frames from its replacement, and the feed
//  projector downstream would see a state it can't reconcile.
//
//  IMPORTANT: nothing in this file retries. A failed or closed connection ends
//  its stream and that is all. See ReconnectingSocket.swift.
//

import Foundation

// MARK: - Frames

nonisolated enum SocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)

    /// Cheesy Arena speaks JSON text frames; this is the convenience the
    /// feed decoder wants. Binary frames are decoded as UTF-8 rather than
    /// dropped, because a server is free to send either for the same payload.
    var textPayload: String? {
        switch self {
        case .text(let string): string
        case .binary(let data): String(data: data, encoding: .utf8)
        }
    }
}

nonisolated enum WebSocketTransportError: Error, Sendable, Equatable {
    /// The peer closed cleanly. Not a bug — a field server restarts between
    /// matches — but still a reason to reconnect.
    case closed(code: Int, reason: String?)
    case failed(message: String)
    case cancelled
    /// A ping or the opening handshake ran out of time. Distinct from
    /// `.failed` because it is the signature of a network that swallows
    /// packets rather than refusing them — the venue's normal failure mode.
    case timedOut
}

// MARK: - Protocols

/// One live connection. Frames arrive on `frames`, which terminates exactly
/// once: normally by finishing, or by throwing when the connection dropped.
nonisolated protocol WebSocketConnection: Sendable {
    /// The frame stream. Single-consumer: an `AsyncThrowingStream` delivers
    /// each element to one iterator, so fanning out to several readers is the
    /// caller's job (ReconnectingSocket does it).
    var frames: AsyncThrowingStream<SocketFrame, any Error> { get }

    func send(_ frame: SocketFrame) async throws

    /// Application-level liveness check. Returns when the pong arrives, and
    /// throws if it does not arrive within a bounded time.
    ///
    /// The bound is not optional. A zombie socket — the AP roamed, or a NAT
    /// table dropped the flow, and TCP has not noticed — answers a ping with
    /// silence, forever. An unbounded ping on such a socket parks its caller
    /// permanently, and the caller here is the liveness watchdog, so the one
    /// mechanism meant to catch a zombie socket would be killed by it.
    func ping() async throws

    /// Idempotent. Ends `frames`.
    func close() async
}

/// Opens connections. Holds no per-connection state.
nonisolated protocol WebSocketTransporting: Sendable {
    func open(_ url: URL, headers: [String: String]) async throws -> any WebSocketConnection
}

nonisolated extension WebSocketTransporting {
    func open(_ url: URL) async throws -> any WebSocketConnection {
        try await open(url, headers: [:])
    }
}

// MARK: - URLSession implementation

actor URLSessionWebSocketTransport: WebSocketTransporting {
    private let session: URLSession
    private let handshakeTimeout: TimeInterval
    private let pingTimeout: TimeInterval

    init(handshakeTimeout: TimeInterval = 10, pingTimeout: TimeInterval = 5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = handshakeTimeout
        // A websocket is expected to sit idle between matches, so the resource
        // timeout must not apply to it the way it would to a download.
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.handshakeTimeout = handshakeTimeout
        self.pingTimeout = pingTimeout
    }

    func open(_ url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        let connection = URLSessionWebSocketConnection(
            session: session,
            url: url,
            headers: headers,
            pingTimeout: pingTimeout
        )
        do {
            // `resume()` returns immediately, so returning here would report a
            // connection that has not completed — or even started — its TCP
            // connect and HTTP upgrade. Callers publish "Connected" the
            // instant this returns, and with the field server off, the IP
            // mistyped, or Local Network permission denied (where packets are
            // dropped in silence) that label would be a flat lie for as long
            // as anyone cared to look at it.
            //
            // A round-tripped ping is the proof: the pong cannot come back
            // until the upgrade has completed.
            try await connection.waitUntilOpen(timeout: handshakeTimeout)
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }
}

/// Wraps one `URLSessionWebSocketTask` and pumps its callback-style receive
/// loop into an `AsyncThrowingStream`.
actor URLSessionWebSocketConnection: WebSocketConnection {
    /// `nonisolated let` so a caller can start iterating without awaiting the
    /// actor first — the stream is fully formed at init.
    nonisolated let frames: AsyncThrowingStream<SocketFrame, any Error>

    private let task: URLSessionWebSocketTask
    private let continuation: AsyncThrowingStream<SocketFrame, any Error>.Continuation
    private let pingTimeout: TimeInterval
    private var pump: Task<Void, Never>?
    private var isClosed = false

    /// The task is built here rather than handed in, so no non-`Sendable`
    /// `URLSessionWebSocketTask` ever crosses an isolation boundary.
    init(session: URLSession, url: URL, headers: [String: String], pingTimeout: TimeInterval = 5) {
        self.pingTimeout = pingTimeout
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        self.task = session.webSocketTask(with: request)

        let (stream, continuation) = AsyncThrowingStream<SocketFrame, any Error>.makeStream()
        self.frames = stream
        self.continuation = continuation

        self.task.resume()
        // Start the pump outside of init's isolation by hopping into the
        // actor; `Task` here captures `self` safely because the actor is fully
        // initialised by this point.
        Task { await self.startPump() }
    }

    private func startPump() {
        guard pump == nil, !isClosed else { return }
        pump = Task { await self.drain() }
    }

    /// Actor-isolated on purpose: `task.receive()` suspends, which releases
    /// the actor, so `close()` and `send()` still get in while this loop is
    /// parked waiting for the next frame. Keeping it isolated also means the
    /// non-`Sendable` `URLSessionWebSocketTask` never escapes.
    private func drain() async {
        do {
            // `receive()` yields one message per call; looping until it throws
            // is the documented way to drain a websocket.
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .string(let text): continuation.yield(.text(text))
                case .data(let data): continuation.yield(.binary(data))
                @unknown default: break
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: mapped(error))
        }
    }

    func send(_ frame: SocketFrame) async throws {
        let message: URLSessionWebSocketTask.Message = switch frame {
        case .text(let text): .string(text)
        case .binary(let data): .data(data)
        }
        do {
            try await task.send(message)
        } catch {
            throw mapped(error)
        }
    }

    func ping() async throws {
        try await ping(timeout: pingTimeout)
    }

    /// Proves the socket is open by round-tripping a ping. Used both as the
    /// idle liveness check and as the handshake gate in `open`.
    func waitUntilOpen(timeout: TimeInterval) async throws {
        try await ping(timeout: timeout)
    }

    private func ping(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.sendPingAwaitingPong() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw WebSocketTransportError.timedOut
            }
            // Whichever finishes first decides; cancelling the group tears the
            // loser down. The real clock is used deliberately — a timeout that
            // could be fast-forwarded by an injected clock would not be a
            // timeout.
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Must be cancellable, not merely racey. A task group waits for *all* its
    /// children before returning, so if this could not be cancelled, losing
    /// the race to the timeout would still leave `ping(timeout:)` parked on
    /// the stuck ping — the exact hang the timeout exists to prevent.
    /// `sendPing` itself cannot be cancelled, so cancellation resolves the
    /// continuation instead and abandons the callback.
    private func sendPingAwaitingPong() async throws {
        let waiter = PingWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiter.attach(continuation)
                task.sendPing { error in
                    if let error {
                        waiter.finish(.failure(WebSocketTransportError.failed(message: error.localizedDescription)))
                    } else {
                        waiter.finish(.success(()))
                    }
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        pump?.cancel()
        pump = nil
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    /// Turns whatever `URLSession` threw into something a human-facing
    /// connection state can be built from. A clean close from the peer is a
    /// `.closed`, not a `.failed` — a field server restarting between matches
    /// should not read as an app error.
    private func mapped(_ error: any Error) -> any Error {
        let closeCode = task.closeCode
        if closeCode != .invalid {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
            return WebSocketTransportError.closed(code: closeCode.rawValue, reason: reason)
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return WebSocketTransportError.cancelled
        }
        if error is CancellationError {
            return WebSocketTransportError.cancelled
        }
        return WebSocketTransportError.failed(message: error.localizedDescription)
    }
}

/// Guards a callback that must only take effect once.
///
/// Resuming a continuation twice is a hard crash, and `sendPing` has been
/// observed to invoke its handler more than once on a task cancelled
/// mid-flight.
nonisolated final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// A continuation that exactly one of three parties resolves: the pong
/// callback, an error callback, or task cancellation. Whoever gets there first
/// wins; the rest are no-ops.
private final class PingWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<Void, any Error>) {
        // Cancellation can land before the continuation is even created, in
        // which case there is nothing stored to resume later and we must
        // resolve it here or leak the task forever.
        let alreadyFinished: Bool = lock.withLock {
            if finished { return true }
            self.continuation = continuation
            return false
        }
        if alreadyFinished { continuation.resume(throwing: CancellationError()) }
    }

    func finish(_ result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
