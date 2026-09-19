//
//  ArenaSocketTests.swift
//  FRC Head Ref HelperTests
//
//  The socket's own behaviour — not the platform's.
//
//  These run against a REAL websocket server on the loopback interface, built
//  with `NetworkListener<WebSocket>`. There is no fake transport and no
//  protocol seam, which is the point: the thing under test is a reconnect
//  supervisor, and a reconnect supervisor tested against a stub that politely
//  ends its stream on request is not tested at all. Here the server really
//  hangs up, the socket really notices, and the handshake really re-runs.
//
//  Loopback needs no Local Network permission, so this works on a simulator
//  and in CI.
//
//  Timings are deliberately tiny — the socket takes its silence timeout and
//  retry ceiling as parameters so the real supervisor can be exercised in
//  milliseconds instead of minutes.
//

import Testing
import Foundation
import Network
@testable import FRC_Head_Ref_Helper

// MARK: - A real arena, small enough to fit in a test

/// A websocket server on 127.0.0.1 that plays the part of Cheesy Arena.
///
/// Not an actor: the accept handler has to be able to sit on a connection for
/// as long as a test wants without blocking calls like `connectionCount`, and
/// actor isolation would serialise exactly those against each other. The only
/// shared state is a counter, so a lock is both smaller and more honest here.
private final class FakeArena: @unchecked Sendable {

    enum ArenaError: Error {
        /// The listener never reported a bound port.
        case neverStarted
    }

    private let listener: NetworkListener<WebSocket>
    private let script: [String]
    /// Whether the server holds the connection open after saying its piece, or
    /// hangs up the way a field server restarting does.
    private let hangUpAfterScript: Bool
    private let lock = NSLock()
    private var acceptLoop: Task<Void, any Error>?
    private var connections = 0

    /// How many clients have been accepted. Two means the socket genuinely
    /// dialled again, rather than the first connection having survived.
    var connectionCount: Int { lock.withLock { connections } }

    init(script: [String], hangUpAfterScript: Bool = false) throws {
        self.script = script
        self.hangUpAfterScript = hangUpAfterScript
        // Port 0 lets the OS pick a free one, so tests cannot collide.
        listener = try NetworkListener(
            using: NWParametersBuilder.parameters { WebSocket { TCP() } }
                .localPort(.any)
        )
        // Without this the listener accepts nothing, which looks from the
        // client's side like a connection reset immediately after the TCP
        // handshake.
        listener.newConnectionLimit = Int.max
    }

    /// Starts listening and returns the URL to point a socket at.
    ///
    /// The port is polled for rather than read straight after construction: the
    /// listener is not bound until `run` has actually started it, and until
    /// then `port` reads back as 0 rather than nil. Treating that 0 as a real
    /// port is a silent way to spend ten seconds connecting to nothing.
    func start() async throws -> URL {
        let loop = Task {
            try await listener.run { connection in
                self.lock.withLock { self.connections += 1 }
                for line in self.script {
                    try? await connection.send(line)
                }
                if self.hangUpAfterScript {
                    try? await connection.close()
                } else {
                    // Hold it open. The test decides when this connection dies,
                    // and a handler that returned early would close it.
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
        lock.withLock { acceptLoop = loop }

        for _ in 0..<300 {
            if let port = listener.port?.rawValue, port != 0 {
                return URL(string: "ws://127.0.0.1:\(port)")!
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ArenaError.neverStarted
    }

    func stop() {
        lock.withLock {
            acceptLoop?.cancel()
            acceptLoop = nil
        }
    }
}

// MARK: - Helpers

/// Waits for the first status matching `predicate`, or fails the test.
///
/// Statuses are consumed from the socket's own stream rather than polled for,
/// so there is no sleep-and-hope anywhere in these tests.
private func awaitStatus(
    from socket: ArenaSocket,
    within timeout: Duration = .seconds(10),
    matching predicate: @escaping @Sendable (ArenaSocket.Status) -> Bool
) async throws -> ArenaSocket.Status {
    try await withThrowingTaskGroup(of: ArenaSocket.Status?.self) { group in
        group.addTask {
            for await status in socket.statuses where predicate(status) {
                return status
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        let first = try await group.next() ?? nil
        return try #require(first, "timed out waiting for a matching status")
    }
}

private func awaitFirstMessage(
    from socket: ArenaSocket,
    within timeout: Duration = .seconds(10)
) async throws -> String {
    try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
            for await data in socket.messages {
                return String(decoding: data, as: UTF8.self)
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        let first = try await group.next() ?? nil
        return try #require(first, "timed out waiting for a message")
    }
}

// MARK: - Tests

// `.serialized` because each test binds a real listening socket and runs a real
// reconnect supervisor. Running a dozen of those at once makes timing-sensitive
// assertions flaky for reasons that have nothing to do with the code.
@Suite("Arena socket", .serialized)
struct ArenaSocketTests {

    @Test("Connects to a real server and delivers its messages", .disabled("""
        Blocked on the test harness, not on ArenaSocket. NetworkListener<WebSocket> never invokes its accept handler on loopback — connectionCount stays 0 and the client sees ECONNRESET straight after the TCP handshake, which points at the server-side websocket upgrade never completing. Tried: waiting for a genuinely bound port (it reads back as 0 until the listener starts), newConnectionLimit, and dropping localOnly. Next thing to try is building the test server with the legacy NWListener + NWProtocolWebSocket.Options.setClientRequestHandler, which is the documented way to accept an upgrade. Everything these cover is still unverified.
        """))
    func deliversMessages() async throws {
        let arena = try FakeArena(script: [#"{"matchState":2}"#])
        let url = try await arena.start()
        defer { arena.stop() }

        let socket = ArenaSocket(url: url)
        await socket.start()
        defer { Task { await socket.stop() } }

        #expect(try await awaitFirstMessage(from: socket) == #"{"matchState":2}"#)
        #expect(await socket.currentStatus.isConnected)
    }

    @Test("Reports a reason when nothing is listening, and keeps trying")
    func retriesAgainstADeadServer() async throws {
        // Bind a port, learn it, then release it — so we have an address on the
        // loopback that is definitely not answering.
        let placeholder = try FakeArena(script: [])
        let deadURL = try await placeholder.start()
        placeholder.stop()

        let socket = ArenaSocket(url: deadURL, retryCap: .milliseconds(50))
        await socket.start()
        defer { Task { await socket.stop() } }

        let waiting = try await awaitStatus(from: socket) {
            if case .waiting = $0 { true } else { false }
        }
        guard case .waiting(_, let attempt, let reason) = waiting else {
            Issue.record("expected a waiting status, got \(waiting)")
            return
        }
        #expect(attempt >= 1)
        // The referee needs to be told something they can act on. A bare
        // "failed" sends them debugging the wrong thing at 7am.
        #expect(!reason.isEmpty)

        // And it has to come back around rather than giving up.
        _ = try await awaitStatus(from: socket) {
            if case .connecting(let attempt) = $0 { attempt >= 2 } else { false }
        }
    }

    @Test("Reconnects when the field server hangs up", .disabled("""
        Blocked on the test harness, not on ArenaSocket. NetworkListener<WebSocket> never invokes its accept handler on loopback — connectionCount stays 0 and the client sees ECONNRESET straight after the TCP handshake, which points at the server-side websocket upgrade never completing. Tried: waiting for a genuinely bound port (it reads back as 0 until the listener starts), newConnectionLimit, and dropping localOnly. Next thing to try is building the test server with the legacy NWListener + NWProtocolWebSocket.Options.setClientRequestHandler, which is the documented way to accept an upgrade. Everything these cover is still unverified.
        """))
    func reconnectsAfterServerHangsUp() async throws {
        // Cheesy Arena restarting between matches, reproduced: the server
        // accepts, says its piece and closes.
        let arena = try FakeArena(script: [#"{"matchState":0}"#], hangUpAfterScript: true)
        let url = try await arena.start()
        defer { arena.stop() }

        let socket = ArenaSocket(url: url, retryCap: .milliseconds(50))
        await socket.start()
        defer { Task { await socket.stop() } }

        _ = try await awaitFirstMessage(from: socket)

        // A second dial is the assertion; a second accepted connection on the
        // server side is the proof it actually reached the wire.
        _ = try await awaitStatus(from: socket) {
            if case .connecting(let attempt) = $0 { attempt >= 2 } else { false }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(arena.connectionCount >= 2)
    }

    @Test("Silence during a match is treated as a dead socket", .disabled("""
        Blocked on the test harness, not on ArenaSocket. NetworkListener<WebSocket> never invokes its accept handler on loopback — connectionCount stays 0 and the client sees ECONNRESET straight after the TCP handshake, which points at the server-side websocket upgrade never completing. Tried: waiting for a genuinely bound port (it reads back as 0 until the listener starts), newConnectionLimit, and dropping localOnly. Next thing to try is building the test server with the legacy NWListener + NWProtocolWebSocket.Options.setClientRequestHandler, which is the documented way to accept an upgrade. Everything these cover is still unverified.
        """))
    func silenceDuringAMatchForcesAReconnect() async throws {
        // The server connects, says nothing, and holds the socket open — which
        // from TCP's point of view is a perfectly healthy connection. This is
        // the zombie case: the match timer on screen would sit frozen while the
        // app went on insisting it was connected.
        let arena = try FakeArena(script: [])
        let url = try await arena.start()
        defer { arena.stop() }

        let socket = ArenaSocket(
            url: url,
            matchSilenceTimeout: .milliseconds(200),
            retryCap: .milliseconds(50)
        )
        await socket.start()
        defer { Task { await socket.stop() } }

        _ = try await awaitStatus(from: socket) { $0.isConnected }
        await socket.setMatchRunning(true)

        let waiting = try await awaitStatus(from: socket) {
            if case .waiting = $0 { true } else { false }
        }
        guard case .waiting(_, _, let reason) = waiting else {
            Issue.record("expected a waiting status, got \(waiting)")
            return
        }
        #expect(reason.contains("No arena data"))
    }

    @Test("Silence outside a match is left alone", .disabled("""
        Blocked on the test harness, not on ArenaSocket. NetworkListener<WebSocket> never invokes its accept handler on loopback — connectionCount stays 0 and the client sees ECONNRESET straight after the TCP handshake, which points at the server-side websocket upgrade never completing. Tried: waiting for a genuinely bound port (it reads back as 0 until the listener starts), newConnectionLimit, and dropping localOnly. Next thing to try is building the test server with the legacy NWListener + NWProtocolWebSocket.Options.setClientRequestHandler, which is the documented way to accept an upgrade. Everything these cover is still unverified.
        """))
    func silenceOutsideAMatchIsNormal() async throws {
        // Between matches the arena genuinely has nothing to say. Dropping a
        // healthy socket here would mean reconnecting every few seconds all day
        // long, which is exactly the traffic we are trying not to generate.
        let arena = try FakeArena(script: [])
        let url = try await arena.start()
        defer { arena.stop() }

        let socket = ArenaSocket(url: url, matchSilenceTimeout: .milliseconds(100))
        await socket.start()
        defer { Task { await socket.stop() } }

        _ = try await awaitStatus(from: socket) { $0.isConnected }
        try await Task.sleep(for: .milliseconds(600))

        #expect(await socket.currentStatus.isConnected)
        #expect(arena.connectionCount == 1)
    }
}

private extension ArenaSocket.Status {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
