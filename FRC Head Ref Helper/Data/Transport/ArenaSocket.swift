//
//  ArenaSocket.swift
//  FRC Head Ref Helper
//
//  The live connection to Cheesy Arena.
//
//  Cheesy Arena pushes arena state over a websocket at ws://10.0.100.5:8080.
//  That connection is how the app knows a match just started, which is the
//  single most time-critical thing it displays.
//
//  ───────────────────────────────────────────────────────────────────────────
//  THERE IS ONE RECONNECT POLICY AND IT IS THIS FILE.
//
//  No feed client may wrap this in a retry loop of its own. Two overlapping
//  schedules mean two sockets briefly alive at once, which means the same
//  arena frame delivered twice — and a downstream projector cannot tell a
//  duplicated frame from a genuinely repeated state, so a match that already
//  ended gets re-applied as live.
//  ───────────────────────────────────────────────────────────────────────────
//
//  Almost all of the machinery this used to need is now in the box. iOS 26's
//  Network framework gives us `NetworkConnection<WebSocket>`, and with it:
//
//    • `messages`  — an AsyncThrowingStream of decoded websocket messages, so
//                    there is no receive-loop to pump by hand.
//    • `onPathUpdate` / `currentPath.unsatisfiedReason` — the OS states
//                    outright when Local Network permission was refused. We
//                    used to guess that from how fast the connect failed.
//    • TCP keepalive — kernel-level proof the socket is still alive, which
//                    replaces an app-level ping timer entirely.
//    • automatic re-preparation when the network path changes, so walking
//                    into range of the field AP is handled for us.
//
//  What is left here is the part Apple cannot know about: how long to wait
//  before dialling again, and the fact that silence during a match is fatal
//  even though the socket still looks healthy.
//

import Foundation
import Network

nonisolated extension Duration {
    /// `Duration` stores attoseconds alongside whole seconds, so reading
    /// `.components.seconds` alone silently truncates anything under a second.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

// MARK: - Socket

/// Keeps one websocket to the arena alive, forever, without any caller having
/// to think about it.
///
/// An `actor` because the app target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; a supervisor that woke the UI
/// thread on every frame would make the match timer stutter.
actor ArenaSocket {

    // MARK: Status

    /// Connection health as *data*.
    ///
    /// A referee's venue network is hostile or absent as the normal case, not
    /// the error case. Throwing into a task nobody is awaiting hides that;
    /// publishing a status lets the UI say "reconnecting, attempt 4" honestly
    /// instead of showing stale data with no explanation.
    ///
    /// Deliberately nested, and deliberately NOT called `ConnectionState`:
    /// that name belongs to the feed layer, whose version of the idea also
    /// folds in staleness. This one is only ever about the socket.
    enum Status: Sendable, Equatable {
        /// Not started, or stopped on purpose.
        case idle
        /// Dialling. `attempt` is 1-based.
        case connecting(attempt: Int)
        case connected(since: Date)
        /// Backing off. `retryAt` is wall clock so the UI can count down.
        case waiting(retryAt: Date, attempt: Int, reason: String)
        /// The OS refused us the local network. This is the one failure with a
        /// fix the referee can actually carry out, so it gets its own case
        /// rather than being buried in a `reason` string.
        case localNetworkDenied
    }

    // MARK: Configuration

    /// How long the socket may be silent *during a running match* before we
    /// declare it dead. Cheesy Arena pushes arena state several times a second
    /// while a match runs, so ten seconds of nothing is not a quiet moment —
    /// it is a socket that TCP has not yet noticed is gone. A head referee
    /// staring at a frozen match timer is the exact failure this app exists to
    /// prevent.
    ///
    /// Outside a match, silence is entirely normal and is policed by TCP
    /// keepalive instead (see `protocolStack`).
    private let matchSilenceTimeout: Duration

    /// Ceiling on the reconnect delay.
    private let retryCap: Duration

    private let url: URL

    // MARK: Published output

    /// Message bodies from whichever connection is currently live. Cheesy
    /// Arena sends JSON, and `JSONDecoder` wants `Data`, so there is nothing
    /// to gain by wrapping these in a frame type.
    ///
    /// Never throws: a failure becomes a `Status`, not an error thrown at a
    /// consumer who would then have to decide whether to retry (they must not).
    nonisolated let messages: AsyncStream<Data>
    nonisolated let statuses: AsyncStream<Status>

    private let messageContinuation: AsyncStream<Data>.Continuation
    private let statusContinuation: AsyncStream<Status>.Continuation

    // MARK: Mutable state

    private var supervisor: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// The task running the current connection. Cancelling it is how anything
    /// in this file forces a reconnect.
    private var session: Task<Void, any Error>?
    /// Cancelled to cut a backoff short when the path comes back.
    private var pendingRetry: Task<Void, Never>?

    /// Consecutive failures. Drives the retry delay, and reset by a connection
    /// that lasted long enough to have been useful.
    private var failures = 0
    private var lastMessageAt: ContinuousClock.Instant?
    private var matchIsRunning = false
    /// Last known path state, so a *change* to satisfied can be told from the
    /// steady stream of "still satisfied" updates.
    private var pathIsSatisfied = true
    /// Set when *we* decide to drop a connection, so the specific diagnosis
    /// survives. Cancelling a session looks like a plain cancellation from the
    /// supervisor's side, and "No arena data for 10s during a match" is far
    /// more useful than "Cancelled".
    private var forcedReason: String?

    private var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            statusContinuation.yield(status)
        }
    }

    var currentStatus: Status { status }

    // MARK: Init

    /// The two durations are parameters rather than constants so tests can run
    /// the real supervisor against a real socket in milliseconds instead of
    /// minutes. Production always takes the defaults.
    init(
        url: URL,
        matchSilenceTimeout: Duration = .seconds(10),
        retryCap: Duration = .seconds(15)
    ) {
        self.url = url
        self.matchSilenceTimeout = matchSilenceTimeout
        self.retryCap = retryCap

        // Newest-wins for messages: a consumer that falls behind should skip to
        // current arena state, not replay a backlog of dead ones. Unbounded for
        // statuses, which are tiny and where dropping one would strand the UI
        // on a stale label.
        let (messages, messageContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.messages = messages
        self.messageContinuation = messageContinuation

        let (statuses, statusContinuation) = AsyncStream<Status>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.statuses = statuses
        self.statusContinuation = statusContinuation
    }

    deinit {
        supervisor?.cancel()
        watchdog?.cancel()
        session?.cancel()
        pendingRetry?.cancel()
        messageContinuation.finish()
        statusContinuation.finish()
    }

    // MARK: Control

    func start() {
        guard supervisor == nil else { return }
        failures = 0
        statusContinuation.yield(status)
        supervisor = Task { await self.superviseForever() }
        watchdog = Task { await self.watchForSilence() }
    }

    func stop() {
        supervisor?.cancel()
        supervisor = nil
        watchdog?.cancel()
        watchdog = nil
        session?.cancel()
        session = nil
        pendingRetry?.cancel()
        pendingRetry = nil
        status = .idle
        // The streams are deliberately NOT finished here. `start()` is
        // re-callable — the referee edits the arena address in Settings, or the
        // app tears the feed down on background and re-arms it on foreground —
        // and a finished continuation is finished forever. The socket would
        // genuinely reconnect while every consumer's `for await` had already
        // ended, leaving a live connection feeding a frozen UI with nothing to
        // explain it. They are finished in `deinit`, when no consumer is left.
    }

    /// Told from outside — the feed projector knows what the arena is doing,
    /// this actor does not. Switching this on tightens the liveness rule from
    /// "TCP keepalive will notice eventually" to "ten seconds of silence is
    /// fatal".
    func setMatchRunning(_ running: Bool) {
        guard matchIsRunning != running else { return }
        matchIsRunning = running
        // Entering a match with an already-stale timestamp would trip the
        // watchdog instantly, so treat the transition as fresh activity.
        lastMessageAt = ContinuousClock.now
    }

    // MARK: Supervision

    private func superviseForever() async {
        while !Task.isCancelled {
            failures += 1
            status = .connecting(attempt: failures)

            let reason = await runOneConnection()
            guard !Task.isCancelled else { return }

            await waitBeforeRetrying(reason: reason)
        }
    }

    /// Runs a single connection to completion and reports why it ended.
    ///
    /// The connection lives inside a child task purely so that `drop(reason:)`
    /// has something to cancel. Cancelling it unwinds `withNetworkConnection`,
    /// which tears the socket down and drops us back into the normal reconnect
    /// path — one route out, whether the failure was organic or our own doing.
    private func runOneConnection() async -> String {
        let session = Task<Void, any Error> {
            try await withNetworkConnection(to: .url(self.url)) {
                self.protocolStack
            } _: { connection in
                self.connectionDidOpen()
                // `onPathUpdate` inherits this actor's isolation, so the handler
                // is already serialised against every other mutation of our
                // state — no hop and no locking needed. Capturing `self`
                // strongly is correct here: the connection cannot outlive
                // `withNetworkConnection`, which is inside a task we own.
                connection.onPathUpdate { _, path in
                    self.handlePathUpdate(path)
                }
                try await self.receive(from: connection)
            }
        }
        self.session = session
        defer { self.session = nil }

        do {
            try await session.value
            // The stream finishing is still a dead socket.
            return takeReason(default: "Connection closed")
        } catch {
            return takeReason(default: Self.describe(error))
        }
    }

    /// The protocol stack, as a value so the reasoning sits in one place.
    ///
    /// `autoReplyPing` lets the framework answer Cheesy Arena's pings without
    /// waking us. The keepalive settings are what let us delete the app's old
    /// five-second ping timer: the kernel probes an idle connection after 10s
    /// and gives up after three failed probes, so a socket that has quietly
    /// died is torn down in roughly 25 seconds without this app sending a
    /// single byte of its own. `connectionTimeout` bounds the dial itself, so a
    /// field server that is switched off fails instead of parking in `waiting`
    /// forever and stalling the supervisor.
    private var protocolStack: WebSocket {
        WebSocket {
            TCP()
                .keepalive(idleTimeInSeconds: 10, count: 3, intervalInSeconds: 5)
                .connectionTimeout(10)
        }
        .autoReplyPing(true)
    }

    private func connectionDidOpen() {
        let now = ContinuousClock.now
        lastMessageAt = now
        status = .connected(since: Date())
    }

    /// Drains one connection's messages. Returning normally means the peer
    /// closed; throwing means it broke.
    private func receive(from connection: NetworkConnection<WebSocket>) async throws {
        for try await (content, metadata) in connection.messages {
            // Control frames are not arena state. `autoReplyPing` has already
            // answered any ping by the time we see it; what matters here is
            // that a pong still counts as proof of life for the watchdog.
            lastMessageAt = ContinuousClock.now
            guard metadata.opcode == .text || metadata.opcode == .binary else { continue }
            messageContinuation.yield(content)
        }
    }

    /// Reads the OS's own explanation instead of inferring one.
    ///
    /// `unsatisfiedReason` is the whole reason the old 200-line timing
    /// heuristic could go: the system states plainly that it refused us the
    /// local network, and a referee can act on that in Settings.
    private func handlePathUpdate(_ path: NWPath) {
        let wasSatisfied = pathIsSatisfied
        pathIsSatisfied = path.status == .satisfied

        switch path.status {
        case .satisfied:
            // Only a path that has just COME BACK is news. A satisfied path
            // reported again — which is the normal case, since every new
            // connection reports one — must not reset the ladder, or the
            // backoff never climbs past its first rung and we spin against a
            // dead server at half-second intervals all morning.
            guard !wasSatisfied else { return }
            failures = 0
            pendingRetry?.cancel()
        case .unsatisfied where path.unsatisfiedReason == .localNetworkDenied:
            status = .localNetworkDenied
            drop(reason: "Local Network permission is off for this app")
        case .unsatisfied, .requiresConnection:
            drop(reason: "Network unavailable")
        @unknown default:
            break
        }
    }

    // MARK: Retry

    /// Why this exists at all, given the framework retries on its own: a
    /// `NetworkConnection` models ONE connection. Network framework will keep
    /// re-preparing it while conditions change, but it will never resurrect a
    /// connection that opened and then died — and Cheesy Arena restarting
    /// between matches does exactly that. Getting another socket means building
    /// another connection, and that loop is ours.
    ///
    /// The delay is the only thing standing between that loop and a tight spin
    /// against a laptop that is switched off all morning during setup. Doubling
    /// to a fifteen-second ceiling turns roughly 1,800 pointless dials an hour
    /// into 240, which is a battery decision more than a bandwidth one on a
    /// phone that has to last a twelve-hour event day.
    private var retryDelay: Duration {
        // Capping the count rather than the result keeps `pow` away from the
        // overflow to `.infinity` that a socket left retrying overnight would
        // otherwise reach.
        min(.seconds(pow(2, Double(min(failures, 16) - 1))), retryCap)
    }

    private func waitBeforeRetrying(reason: String) async {
        let delay = retryDelay
        // `.localNetworkDenied` is already a more useful thing to show than a
        // countdown the referee can do nothing about; don't overwrite it.
        if status != .localNetworkDenied {
            status = .waiting(
                retryAt: Date().addingTimeInterval(delay.seconds),
                attempt: failures,
                reason: reason
            )
        }
        // A separate cancellable task so a returning network path can cut the
        // wait short without tearing down the supervisor.
        let retry = Task<Void, Never> { try? await Task.sleep(for: delay) }
        pendingRetry = retry
        await retry.value
        pendingRetry = nil
    }

    // MARK: Liveness

    /// Fires when a running match goes quiet.
    ///
    /// This sleeps to the deadline rather than polling on a tick: with no match
    /// running it wakes once per silence window, and with one running it wakes
    /// exactly when the budget would expire. Each message pushes the deadline
    /// out, so the re-check after waking is what makes that correct.
    private func watchForSilence() async {
        while !Task.isCancelled {
            guard matchIsRunning, session != nil, let last = lastMessageAt else {
                try? await Task.sleep(for: matchSilenceTimeout)
                continue
            }

            let remaining = ContinuousClock.now.duration(to: last.advanced(by: matchSilenceTimeout))
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
                continue
            }

            drop(reason: "No arena data for \(Int(matchSilenceTimeout.seconds))s during a match")
            // Give the supervisor a moment to notice, so we do not spin on a
            // connection that is already on its way out.
            try? await Task.sleep(for: matchSilenceTimeout)
        }
    }

    /// Ends the current connection, which unwinds the session task and drops
    /// the supervisor into its normal reconnect path.
    private func drop(reason: String) {
        guard session != nil else { return }
        forcedReason = reason
        session?.cancel()
    }

    /// A reason we set on purpose beats whatever the failure looked like from
    /// the outside.
    private func takeReason(default fallback: String) -> String {
        defer { forcedReason = nil }
        return forcedReason ?? fallback
    }

    private static func describe(_ error: any Error) -> String {
        if error is CancellationError { return "Cancelled" }
        if let error = error as? NWError {
            switch error {
            case .posix(.ECONNREFUSED):
                // Worth naming: something answered and said no, so the address
                // and the permission are both fine and Cheesy Arena simply is
                // not running.
                return "Nothing is listening on that port — is Cheesy Arena running?"
            case .posix(.ETIMEDOUT):
                return "Timed out"
            default:
                return error.localizedDescription
            }
        }
        return (error as NSError).localizedDescription
    }
}
