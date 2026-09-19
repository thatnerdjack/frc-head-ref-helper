//
//  CheesyArenaClient.swift
//  FRC Head Ref Helper
//
//  The field, as this app sees it.
//
//  Owns one `ArenaSocket` to ws://<host>:8080/api/arena/websocket and turns its
//  raw frames into `ArenaEvent`s. That endpoint is unauthenticated and carries
//  matchTiming, matchLoad and matchTime — which is precisely the head
//  referee's question: what match is on the field, who is on it, and what is
//  the field doing right now.
//
//  This client does NOT retry. ArenaSocket owns the one reconnect policy in
//  this app; see the banner in ArenaSocket.swift for why there is exactly one.
//
//  Schedule comes over REST rather than the socket, because the socket only
//  ever announces the match that is currently loaded. Without the schedule
//  there is no "next match", and "next match" is half of what the Now screen
//  is for.
//

import Foundation

// MARK: - Events

/// What the field just told us.
nonisolated enum ArenaEvent: Sendable, Equatable {
    /// The field loaded a match. Carries the match as this app models it,
    /// including which play it is.
    case matchLoaded(Match)
    /// The field's state changed, with seconds elapsed in the current period.
    case matchTime(state: ArenaMatchState, secondsIntoPeriod: Int)
    /// Connection health, passed through for the UI to show honestly.
    case status(ArenaSocket.Status)
}

// MARK: - Client

actor CheesyArenaClient {

    private let endpoints: ArenaEndpoints
    private let socket: ArenaSocket
    private let http: HTTPService

    private let (eventStream, eventContinuation) = AsyncStream<ArenaEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(64)
    )
    /// Everything the field says, in order.
    nonisolated var events: AsyncStream<ArenaEvent> { eventStream }

    private var pump: Task<Void, Never>?
    private var statusPump: Task<Void, Never>?

    /// How many times each match has been loaded. Cheesy Arena reports
    /// `IsReplay` as a flag, not a count, so the count is kept here — a match
    /// replayed twice after an ARENA FAULT has to be play 3, or entries logged
    /// during the second running silently merge into the first.
    private var plays: [String: Int] = [:]

    init(host: String, port: Int = 8080) {
        self.endpoints = ArenaEndpoints(host: host, port: port)
        // Force-unwrap is safe: the string is built from a validated host and
        // an Int, and a failure here would mean URL parsing itself is broken.
        self.socket = ArenaSocket(url: endpoints.websocket ?? URL(string: "ws://127.0.0.1:8080")!)
        self.http = HTTPService()
    }

    func start() async {
        guard pump == nil else { return }
        await socket.start()

        pump = Task { [socket, eventContinuation] in
            for await data in socket.messages {
                guard let event = self.decode(data) else { continue }
                eventContinuation.yield(event)
            }
            _ = socket
        }

        statusPump = Task { [socket, eventContinuation] in
            for await status in socket.statuses {
                eventContinuation.yield(.status(status))
            }
            _ = socket
        }
    }

    func stop() async {
        pump?.cancel()
        pump = nil
        statusPump?.cancel()
        statusPump = nil
        await socket.stop()
    }

    /// Told from outside so the socket can tighten its liveness rule while a
    /// match is running. The client knows this before the socket does.
    func setMatchRunning(_ running: Bool) async {
        await socket.setMatchRunning(running)
    }

    // MARK: Decoding

    /// Returns nil for any frame this app does not act on.
    ///
    /// An unrecognised `type` is a no-op, never an error. The arena sends
    /// sounds, lower thirds and display-mode changes down the same socket, and
    /// a decoder that threw on those would take the connection with it.
    private func decode(_ data: Data) -> ArenaEvent? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(ArenaEnvelope.self, from: data) else {
            return nil
        }

        switch envelope.type {
        case "matchTime":
            guard let frame = try? decoder.decode(ArenaMatchTimeFrame.self, from: data),
                  let state = frame.data.state else { return nil }
            return .matchTime(state: state, secondsIntoPeriod: frame.data.MatchTimeSec)

        case "matchLoad":
            guard let frame = try? decoder.decode(ArenaMatchLoadFrame.self, from: data),
                  let match = match(from: frame.data) else { return nil }
            return .matchLoaded(match)

        default:
            return nil
        }
    }

    private func match(from load: ArenaMatchLoad) -> Match? {
        let raw = load.Match
        guard let level = raw.level else { return nil }   // a Test match
        // Keyed off the wire's own type/order ints rather than the model's
        // `MatchLevel.prefix`, so this stays clear of the app model's
        // main-actor isolation.
        let play = playNumber(for: "\(raw.Type)-\(raw.TypeOrder)",
                              isReplay: load.IsReplay ?? false)
        return Match(
            key: MatchKey(level: level, number: raw.TypeOrder, play: play),
            red: raw.redTeams,
            blue: raw.blueTeams,
            scheduledStart: raw.scheduledStart,
            actualStart: raw.actualStart
        )
    }

    /// Turns the arena's `IsReplay` flag into this app's play number.
    ///
    /// First load is play 1. Each subsequent load flagged as a replay bumps the
    /// count, so a match replayed twice reads as play 3. Reloading the same
    /// match without the replay flag — which the field does when an operator
    /// re-selects a match before running it — does not bump anything.
    private func playNumber(for shortKey: String, isReplay: Bool) -> Int {
        let current = plays[shortKey] ?? 0
        guard current > 0 else {
            plays[shortKey] = 1
            return 1
        }
        guard isReplay else { return current }
        let next = current + 1
        plays[shortKey] = next
        return next
    }

    // MARK: Schedule

    /// Fetches one level's schedule over REST.
    ///
    /// Separate from the socket on purpose: the socket only ever announces the
    /// currently loaded match, so "what is next" has to come from here. Goes
    /// through `HTTPService`, which means URLCache revalidates it and an
    /// unchanged schedule costs nothing to re-poll.
    func schedule(_ level: ArenaLevelName) async throws -> [Match]? {
        guard let url = endpoints.matches(level) else { return nil }
        let result = try await http.get(url)
        guard case .changed(let data) = result else { return nil }   // unchanged

        let rows = try JSONDecoder().decode([ArenaMatchWithResult].self, from: data)
        return rows.compactMap { row in
            guard let level = row.Match.level else { return nil }
            return Match(
                key: MatchKey(level: level, number: row.Match.TypeOrder),
                red: row.Match.redTeams,
                blue: row.Match.blueTeams,
                scheduledStart: row.Match.scheduledStart,
                actualStart: row.Match.actualStart
            )
        }
    }
}
