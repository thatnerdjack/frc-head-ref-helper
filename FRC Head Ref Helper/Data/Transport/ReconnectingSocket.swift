//
//  ReconnectingSocket.swift
//  FRC Head Ref Helper
//
//  THE retry policy. Singular, deliberately.
//
//  ───────────────────────────────────────────────────────────────────────────
//  CLIENTS MUST NEVER RETRY INTERNALLY.
//
//  Every feed client in this app calls a transport and either gets data or
//  gets a connection state. None of them may wrap that in their own loop.
//  If each client had its own backoff you get several overlapping schedules
//  hammering the same field server, and — much worse — you get the same frame
//  delivered twice from two connections that were briefly alive at once.
//  Duplicate frames are precisely what breaks replay detection downstream:
//  the projector cannot tell a genuinely repeated arena state from a frame it
//  already applied, so a match that already ended gets re-applied as live.
//  One socket, one policy, one place to fix it. This file.
//  ───────────────────────────────────────────────────────────────────────────
//
//  Three things force a reconnect, and they are not the same thing:
//
//   1. The connection ended (error or clean close). Back off and retry.
//   2. The network path changed — someone finally joined the field's SSID, or
//      the phone flipped from cellular to Wi-Fi. Waiting out a 15-second
//      backoff here would be absurd when the reason for the failure has just
//      been fixed, so a path change cancels the pending wait immediately.
//   3. The socket is open but silent. Cheesy Arena pushes constantly while a
//      match runs, so more than 10 seconds of silence *during a match* means
//      the connection is a zombie — TCP has not noticed yet, but the data is
//      gone, and a head referee staring at a frozen match timer is exactly the
//      failure this app exists to prevent. Outside a match, silence is normal,
//      so we fall back to a 5-second ping to prove the socket is still there.
//

import Foundation
import Network

// MARK: - Connection state

/// Connection health as *data*.
///
/// A referee's venue network is hostile or absent as the normal case, not the
/// error case. Throwing an error into a task nobody is awaiting hides that;
/// publishing a state lets the UI say "reconnecting, attempt 4" honestly
/// instead of showing stale data with no explanation.
nonisolated enum ConnectionState: Sendable, Equatable {
    /// Not started, or deliberately stopped.
    case idle
    /// Handshake in flight. `attempt` is 1-based.
    case connecting(attempt: Int)
    /// Open and receiving.
    case connected(since: Date)
    /// Backing off. `retryAt` is wall clock so the UI can count down.
    case waiting(retryAt: Date, attempt: Int, reason: String)
    /// `NWPathMonitor` reports no usable path. Retrying is pointless until
    /// that changes, so we park here rather than burning attempts.
    case offline
    /// Stopped and not coming back without user action.
    case failed(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Backoff

/// The delay schedule, as a pure value so it can be asserted on directly.
///
/// 0.5 → 1 → 2 → 4 → 8 → 15 (capped), with ±20% jitter. The jitter matters
/// more than it looks: at an event the phone, the tablet and the scoring
/// laptop all lose the field server at the same instant, and without jitter
/// they all come back at the same instant too, producing a thundering herd
/// against a server that is probably still booting.
nonisolated struct BackoffPolicy: Sendable, Equatable {
    var base: TimeInterval = 0.5
    var multiplier: Double = 2
    /// A hard ceiling: jitter is applied and *then* clamped, so a delay never
    /// exceeds this even on the high side.
    var cap: TimeInterval = 15
    /// ±20%.
    var jitterFraction: Double = 0.2
    /// Stay connected this long and the ladder resets to `base`. Without this,
    /// a socket that drops once an hour would eventually sit at the 15-second
    /// cap forever, and the reconnect after a genuinely brief blip would feel
    /// broken.
    var healthyResetAfter: TimeInterval = 30

    /// - Parameters:
    ///   - attempt: 1-based. Attempt 1 is the delay *before* the second
    ///     connection try; the first try is immediate.
    ///   - jitter: −1...1, scaled by `jitterFraction`. Injected so tests get a
    ///     deterministic schedule instead of asserting on a range.
    func delay(forAttempt attempt: Int, jitter: Double) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        // pow() on a large attempt count overflows to .infinity long before
        // Int overflows, and .infinity * jitter is NaN — clamp the exponent.
        let exponent = Double(min(attempt - 1, 32))
        let nominal = min(base * pow(multiplier, exponent), cap)
        let scaled = nominal * (1 + max(-1, min(1, jitter)) * jitterFraction)
        return max(0, min(scaled, cap))
    }

    /// Production path: uniform jitter.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        delay(forAttempt: attempt, jitter: Double.random(in: -1...1))
    }
}

// MARK: - Network path

/// The parts of `NWPath` we act on, flattened into a `Sendable` value at the
/// moment the monitor hands it over. `NWPath` itself is not `Sendable`, and
/// letting it leak out of the update handler would be a data race.
nonisolated struct NetworkPathSnapshot: Sendable, Equatable {
    var isSatisfied: Bool
    var isExpensive: Bool
    var usesWiFi: Bool
    /// A change here means a genuinely different route, which is the signal
    /// worth reconnecting on.
    var interfaceSignature: String

    static let unknown = NetworkPathSnapshot(
        isSatisfied: true, isExpensive: false, usesWiFi: false, interfaceSignature: "unknown"
    )
}

/// Wraps `NWPathMonitor` in an `AsyncStream`.
///
/// Available on every platform this app ships to, including watchOS, so no
/// `#if os` guard is needed — which is good, because the watch is the device
/// most likely to be roaming between the venue AP and the phone.
nonisolated struct NetworkPathMonitor: Sendable {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "me.jackdoherty.refhelper.path")) {
        self.queue = queue
    }

    func paths() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(Self.snapshot(of: path))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }

    static func snapshot(of path: NWPath) -> NetworkPathSnapshot {
        let interfaces = path.availableInterfaces
            .map { "\($0.name):\($0.type)" }
            .sorted()
            .joined(separator: ",")
        return NetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            isExpensive: path.isExpensive,
            usesWiFi: path.usesInterfaceType(.wifi),
            interfaceSignature: "\(path.status)|\(interfaces)"
        )
    }
}

// MARK: - Reconnecting socket

/// Keeps one websocket alive, forever, without any caller having to think
/// about it.
///
/// An `actor` because the app target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; a supervisor that woke the UI
/// thread on every frame would make the match timer stutter.
actor ReconnectingSocket<C: Clock> where C.Duration == Duration {
    // MARK: Configuration

    /// How long the socket may be silent *during a running match* before we
    /// declare it dead. Cheesy Arena pushes arena state several times a
    /// second while a match runs.
    private let matchSilenceTimeout: TimeInterval = 10
    /// Ping cadence when no match is running, where silence is expected.
    private let idlePingInterval: TimeInterval = 5
    /// Watchdog tick. Finer than either threshold so neither overshoots by
    /// much, coarse enough not to matter for battery.
    private let watchdogTick: TimeInterval = 1

    private let url: URL
    private let headers: [String: String]
    private let transport: any WebSocketTransporting
    private let clock: C
    private let backoff: BackoffPolicy
    private let pathMonitor: NetworkPathMonitor?

    // MARK: Published output

    /// Frames from whichever connection is currently live. Never throws: a
    /// failure becomes a `ConnectionState`, not an error thrown at a consumer
    /// who would then have to decide whether to retry (they must not).
    nonisolated let frames: AsyncStream<SocketFrame>
    nonisolated let states: AsyncStream<ConnectionState>

    private let frameContinuation: AsyncStream<SocketFrame>.Continuation
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    // MARK: Mutable state

    private var supervisor: Task<Void, Never>?
    private var pathObserver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Cancelled to cut a backoff wait short when the path changes.
    private var pendingRetry: Task<Void, Never>?
    private var connection: (any WebSocketConnection)?

    private var attempt = 0
    private var connectedAt: C.Instant?
    private var lastFrameAt: C.Instant?
    private var lastPingAt: C.Instant?
    private var matchIsRunning = false
    private var lastPath: NetworkPathSnapshot = .unknown
    /// Why we are reconnecting, carried into `.waiting` so the UI can say
    /// something more useful than "reconnecting".
    private var lastReason = "Disconnected"
    /// Set when *we* decided to drop the connection, so the specific
    /// diagnosis survives. Closing a socket ends its frame stream cleanly, so
    /// the supervisor would otherwise report the generic "Connection closed"
    /// — and the three cases where this app actually knows something useful
    /// ("No arena data for 10s during a match", "Ping failed", "Network
    /// unavailable") are exactly the three it would throw away.
    private var forcedReason: String?
    private var state: ConnectionState = .idle {
        didSet {
            guard state != oldValue else { return }
            stateContinuation.yield(state)
        }
    }

    // MARK: Init

    init(
        url: URL,
        headers: [String: String] = [:],
        transport: any WebSocketTransporting,
        clock: C = ContinuousClock(),
        backoff: BackoffPolicy = BackoffPolicy(),
        pathMonitor: NetworkPathMonitor? = NetworkPathMonitor()
    ) {
        self.url = url
        self.headers = headers
        self.transport = transport
        self.clock = clock
        self.backoff = backoff
        self.pathMonitor = pathMonitor

        // `.unbounded` for states (they are tiny and losing one would strand
        // the UI on a stale label) and a bounded newest-wins buffer for frames
        // (a consumer that falls behind should skip to current arena state,
        // not replay a backlog of dead ones).
        let (frameStream, frameContinuation) = AsyncStream<SocketFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.frames = frameStream
        self.frameContinuation = frameContinuation

        let (stateStream, stateContinuation) = AsyncStream<ConnectionState>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.states = stateStream
        self.stateContinuation = stateContinuation
    }

    // MARK: Control

    func start() {
        guard supervisor == nil else { return }
        attempt = 0
        stateContinuation.yield(state)
        supervisor = Task { await self.runForever() }
        if let pathMonitor {
            // These child tasks inherit this actor's isolation, so they are
            // serialised against every other mutation of our state — no
            // separate locking, and no `await` needed on the hop back in.
            pathObserver = Task { [pathMonitor] in
                for await path in pathMonitor.paths() {
                    self.handlePathChange(path)
                }
            }
        }
        watchdog = Task { await self.runWatchdog() }
    }

    func stop() async {
        supervisor?.cancel()
        supervisor = nil
        pathObserver?.cancel()
        pathObserver = nil
        watchdog?.cancel()
        watchdog = nil
        pendingRetry?.cancel()
        pendingRetry = nil
        await connection?.close()
        connection = nil
        state = .idle
        // The streams are deliberately NOT finished here. `start()` is
        // re-callable — the referee edits the arena address in Settings, or
        // the app tears the feed down on background and re-arms it on
        // foreground — and a finished continuation is finished forever. The
        // socket would genuinely reconnect while every consumer's `for await`
        // had already ended, leaving a live connection feeding a frozen UI
        // with nothing to explain it. They are finished in `deinit` instead,
        // when there is no possible consumer left.
    }

    deinit {
        supervisor?.cancel()
        pathObserver?.cancel()
        watchdog?.cancel()
        pendingRetry?.cancel()
        frameContinuation.finish()
        stateContinuation.finish()
    }

    /// Told from outside — the feed projector knows what the arena is doing,
    /// this actor does not. Switching this on tightens the liveness rule from
    /// "ping every 5s" to "10s of silence is fatal".
    func setMatchRunning(_ running: Bool) {
        guard matchIsRunning != running else { return }
        matchIsRunning = running
        // Entering a match with an already-stale timestamp would fire the
        // watchdog instantly, so treat the transition as fresh activity.
        lastFrameAt = clock.now
    }

    var currentState: ConnectionState { state }

    // MARK: Supervision

    private func runForever() async {
        while !Task.isCancelled {
            if !lastPath.isSatisfied {
                state = .offline
                // Nothing to do but wait for handlePathChange to wake us; the
                // backoff wait below doubles as that parking spot.
                await waitForRetry(seconds: backoff.cap, reason: "No network")
                continue
            }

            attempt += 1
            state = .connecting(attempt: attempt)

            do {
                let connection = try await transport.open(url, headers: headers)
                self.connection = connection
                let openedAt = clock.now
                connectedAt = openedAt
                lastFrameAt = openedAt
                lastPingAt = openedAt
                state = .connected(since: Date())

                // Consuming the frame stream blocks here until the connection
                // ends, which is what makes this loop a supervisor.
                try await consume(connection)
                // A clean finish still means the socket is gone.
                await handleDisconnect(reason: "Connection closed")
            } catch is CancellationError {
                return
            } catch {
                await handleDisconnect(reason: Self.describe(error))
            }

            guard !Task.isCancelled else { return }
            await waitForRetry(seconds: backoff.delay(forAttempt: attempt), reason: lastReason)
        }
    }

    private func consume(_ connection: any WebSocketConnection) async throws {
        for try await frame in connection.frames {
            lastFrameAt = clock.now
            frameContinuation.yield(frame)
        }
    }

    private func handleDisconnect(reason: String) async {
        // A reason we set on purpose beats whatever the stream ending looked
        // like from here.
        lastReason = forcedReason ?? reason
        forcedReason = nil
        await connection?.close()
        connection = nil

        // Reset the ladder only if the connection actually held up. A socket
        // that connects and dies immediately must keep climbing, or we would
        // spin at 0.5s forever against a server that is refusing us.
        if let connectedAt,
           connectedAt.duration(to: clock.now) >= .seconds(backoff.healthyResetAfter) {
            attempt = 0
        }
        connectedAt = nil
    }

    /// The wait is a separate cancellable task so `handlePathChange` can end it
    /// early without tearing down the supervisor.
    private func waitForRetry(seconds: TimeInterval, reason: String) async {
        guard seconds > 0 else { return }
        // `.offline` is already a more informative state than "waiting 15s";
        // don't overwrite it with a countdown the user can do nothing about.
        if state != .offline {
            state = .waiting(
                retryAt: Date().addingTimeInterval(seconds),
                attempt: attempt,
                reason: reason
            )
        }
        // The `Void` annotation matters: `try?` on a Void call yields `()?`,
        // which would make this a Task<()?, Never> and not match the property.
        let task = Task<Void, Never> { [clock] in try? await clock.sleep(for: .seconds(seconds)) }
        pendingRetry = task
        await task.value
        pendingRetry = nil
    }

    // MARK: Path changes

    private func handlePathChange(_ path: NetworkPathSnapshot) {
        let previous = lastPath
        lastPath = path
        guard path != previous else { return }

        if path.isSatisfied {
            // The route just changed or came back. Whatever we were waiting
            // for has likely just been fixed by the user walking into range,
            // so reset the ladder and stop waiting.
            attempt = 0
            pendingRetry?.cancel()
        } else if state.isConnected {
            // The path is gone; the socket is dead even though it has not
            // noticed. Drop it now so the UI stops implying live data.
            forceReconnect(reason: "Network unavailable")
        }
    }

    // MARK: Liveness

    private func runWatchdog() async {
        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(watchdogTick))
            guard !Task.isCancelled, state.isConnected, let connection else { continue }

            let now = clock.now
            if matchIsRunning {
                // Silence during a match is a zombie socket, full stop. Do not
                // ping and hope — a ping that succeeds on a connection whose
                // data has stopped would just extend the lie.
                if let lastFrameAt, lastFrameAt.duration(to: now) > .seconds(matchSilenceTimeout) {
                    forceReconnect(reason: "No arena data for \(Int(matchSilenceTimeout))s during a match")
                }
            } else if lastPingAt.map({ $0.duration(to: now) >= .seconds(idlePingInterval) }) ?? true {
                lastPingAt = now
                do {
                    try await connection.ping()
                } catch {
                    forceReconnect(reason: "Ping failed")
                }
            }
        }
    }

    /// Ends the current connection, which unblocks `consume` and drops the
    /// supervisor into its normal reconnect path. Going through the same path
    /// as an organic failure is the point: one reconnect route, not two.
    private func forceReconnect(reason: String) {
        forcedReason = reason
        let connection = self.connection
        self.connection = nil
        Task { await connection?.close() }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as WebSocketTransportError:
            switch error {
            case .closed(let code, let reason): "Closed (\(code))\(reason.map { ": \($0)" } ?? "")"
            case .failed(let message): message
            case .cancelled: "Cancelled"
            // Worth naming separately in the connection banner: a venue network
            // that swallows packets looks like nothing at all happening, which
            // is very different from a server that refused us.
            case .timedOut: "Timed out"
            }
        default:
            (error as NSError).localizedDescription
        }
    }
}
