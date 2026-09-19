//
//  ArenaSocketTests.swift
//  FRC Head Ref HelperTests
//
//  The socket's own behaviour — not the platform's.
//
//  These run against a REAL websocket server on the loopback interface (see
//  Support/FakeArena.swift). There is no fake transport and no protocol seam,
//  which is the point: the thing under test is a reconnect supervisor, and a
//  reconnect supervisor tested against a stub that politely ends its stream on
//  request is not tested at all. Here the server really hangs up, the socket
//  really notices, and the handshake really re-runs.
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

private extension ArenaSocket.Status {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}


// MARK: - Cheesy Arena payloads
//
// Real frame shapes, kept beside the socket tests because the client tests
// below must share this suite's serialization: these bind real listeners, and
// two suites doing that in parallel crashed the test process.

let matchLoadJSON = """
{"type":"matchLoad","data":{"Match":{"Id":41,"Type":2,"TypeOrder":41,\
"Time":"2026-09-19T10:30:00-07:00","LongName":"Qualification 41","ShortName":"Q41",\
"NameDetail":"","Red1":8341,"Red2":254,"Red3":971,"Blue1":1678,"Blue2":604,"Blue3":100,\
"StartedAt":"0001-01-01T00:00:00Z","ScoreCommittedAt":"0001-01-01T00:00:00Z","Status":0},\
"IsReplay":false,"Teams":{}}}
"""

let matchTimeJSON = """
{"type":"matchTime","data":{"MatchState":2,"MatchTimeSec":8}}
"""

/// A notifier this app does not act on. Must be ignored, not fatal.
let unknownJSON = """
{"type":"playSound","data":{"Name":"match_start"}}
"""

// MARK: - Tests

// `.serialized` because each test binds a real listening socket and runs a real
// reconnect supervisor. Running a dozen of those at once makes timing-sensitive
// assertions flaky for reasons that have nothing to do with the code.
@Suite("Arena socket", .serialized)
struct ArenaSocketTests {

    @Test("Connects to a real server and delivers its messages")
    func deliversMessages() async throws {
        let arena = try FakeArena(script: [#"{"matchState":2}"#])
        let url = try await arena.start()
        defer { arena.stop() }

        let socket = ArenaSocket(url: url)
        await socket.start()
        defer { Task { await socket.stop() } }

        #expect(try await awaitFirstMessage(from: socket) == #"{"matchState":2}"#)
        #expect(await socket.currentStatus.isConnected)
        #expect(arena.connectionCount == 1)
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

    @Test("Reconnects when the field server hangs up")
    func reconnectsAfterServerHangsUp() async throws {
        // Cheesy Arena restarting between matches, reproduced: the server
        // accepts, says its piece and closes.
        let arena = try FakeArena(script: [#"{"matchState":0}"#], behaviour: .hangUp)
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
        try await Task.sleep(for: .milliseconds(500))
        #expect(arena.connectionCount >= 2)
    }

    @Test("Silence during a match is treated as a dead socket")
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
            matchSilenceTimeout: .milliseconds(300),
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

    @Test("Silence outside a match is left alone")
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
        try await Task.sleep(for: .milliseconds(700))

        #expect(await socket.currentStatus.isConnected)
        #expect(arena.connectionCount == 1)
    }

    // MARK: - Cheesy Arena client, end to end


    /// Pulls the port back out of FakeArena's URL so the client can build its
    /// own `/api/arena/websocket` address against it. FakeArena accepts the
    /// upgrade on any path, which is what makes that work.
    private func port(of url: URL) throws -> Int {
        try #require(url.port)
    }

    // @MainActor because the assertions read `Match`, whose members are
    // main-actor isolated under this target's default isolation.
    @MainActor
    @Test("A real matchLoad frame arrives as a mapped match")
    func endToEndMatchLoad() async throws {
        let arena = try FakeArena(script: [matchLoadJSON])
        let url = try await arena.start()
        defer { arena.stop() }

        let client = CheesyArenaClient(host: "127.0.0.1", port: try port(of: url))
        await client.start()
        defer { Task { await client.stop() } }

        let event = try await firstMatchEvent(from: client)
        guard case .matchLoaded(let match) = event else {
            Issue.record("expected a matchLoaded event, got \(event)")
            return
        }
        #expect(match.key == MatchKey(level: .qualification, number: 41))
        #expect(match.red == ["8341", "254", "971"])
    }

    // @MainActor because the assertions read `Match`, whose members are
    // main-actor isolated under this target's default isolation.
    @MainActor
    @Test("An unknown notifier is ignored and does not break the feed")
    func unknownFrameIsIgnored() async throws {
        // The arena sends sounds and display modes down the same socket. A
        // decoder that treated those as fatal would drop the connection every
        // time a match started.
        let arena = try FakeArena(script: [unknownJSON, matchTimeJSON])
        let url = try await arena.start()
        defer { arena.stop() }

        let client = CheesyArenaClient(host: "127.0.0.1", port: try port(of: url))
        await client.start()
        defer { Task { await client.stop() } }

        let event = try await firstMatchEvent(from: client)
        guard case .matchTime(let state, let seconds) = event else {
            Issue.record("expected a matchTime event, got \(event)")
            return
        }
        #expect(state == .autoPeriod)
        #expect(seconds == 8)
    }

    /// The first event that is not a connection-status change.
    private func firstMatchEvent(
        from client: CheesyArenaClient,
        within timeout: Duration = .seconds(10)
    ) async throws -> ArenaEvent {
        try await withThrowingTaskGroup(of: ArenaEvent?.self) { group in
            group.addTask {
                for await event in client.events {
                    if case .status = event { continue }
                    return event
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            let first = try await group.next() ?? nil
            return try #require(first, "timed out waiting for an arena event")
        }
    }
}
