//
//  TimeSource.swift
//  FRC Head Ref Helper
//
//  An injectable clock.
//
//  Everything in the transport layer is time-dependent: backoff delays, the
//  "healthy for 30 seconds" reset, the silence watchdog. If those read the
//  real clock, testing them means really sleeping, and a test that proves the
//  cap is 15 seconds takes over a minute to run — so nobody runs it, so the
//  backoff schedule silently rots. Injecting the clock makes those tests
//  instant, which is the only reason they will still exist next season.
//
//  Two readings, on purpose:
//
//    • `now` is wall clock. It is what a human-facing state ("retrying at
//      3:41:07") should be stamped with.
//    • `monotonicSeconds` never runs backwards. Intervals — "has the field
//      server been silent for 10 seconds?" — must use this one. An iPhone that
//      picks up NTP the moment it joins the venue Wi-Fi can jump its wall
//      clock by minutes, and a watchdog measured against a jumping clock will
//      either fire constantly or never fire at all.
//

import Foundation

// MARK: - Protocol

/// The clock the transport layer reads. Deliberately tiny: three members is
/// the whole surface a test double has to fake.
nonisolated protocol TimeSource: Sendable {
    /// Wall-clock instant, for timestamps a person will read.
    var now: Date { get }

    /// Monotonically increasing seconds from an arbitrary origin. Only
    /// differences are meaningful; never compare against `now`.
    var monotonicSeconds: TimeInterval { get }

    /// Suspends for `seconds`. Throws `CancellationError` if the surrounding
    /// task is cancelled, which is how a pending backoff wait gets cut short
    /// when the network path changes.
    func sleep(seconds: TimeInterval) async throws
}

// MARK: - Production clock

nonisolated struct SystemTimeSource: TimeSource {
    /// `ContinuousClock` keeps counting while the device is asleep, unlike
    /// `SuspendingClock`. A referee's phone locks in a pocket between matches
    /// and we still want elapsed time to reflect reality when it wakes.
    private let origin = ContinuousClock.now

    init() {}

    var now: Date { Date() }

    var monotonicSeconds: TimeInterval {
        (ContinuousClock.now - origin).asSeconds
    }

    func sleep(seconds: TimeInterval) async throws {
        // Negative or zero waits are legal inputs (a backoff already elapsed);
        // Task.sleep would trap on a negative Duration.
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Test clock

/// A clock the tests drive by hand.
///
/// `sleep` does not sleep: it records the requested duration and advances the
/// virtual clock instantly. That makes a test of the full backoff ladder —
/// including the 15-second cap — run in microseconds, and it turns the delay
/// schedule into something you can assert on directly rather than infer from
/// wall-clock timing, which would be flaky on a loaded CI machine.
///
/// Lives in app code rather than the test bundle so every test target and
/// every transport test double shares one implementation.
nonisolated final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _monotonic: TimeInterval
    private var _requestedSleeps: [TimeInterval] = []

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self._now = now
        self._monotonic = 0
    }

    var now: Date { lock.withLock { _now } }

    var monotonicSeconds: TimeInterval { lock.withLock { _monotonic } }

    /// Every duration handed to `sleep`, in order. This is the assertion
    /// target for backoff tests.
    var requestedSleeps: [TimeInterval] { lock.withLock { _requestedSleeps } }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { _requestedSleeps.append(seconds) }

        // Cancellation is checked BEFORE the clock moves. A backoff cut short
        // by a network path change did not actually take 15 seconds, and a
        // test asserting that behaviour would otherwise pass for the wrong
        // reason.
        try Task.checkCancellation()

        // A real sleep suspends; this one must too. Without a suspension point
        // a `while true { await clock.sleep(1) }` watchdog is a spin loop that
        // never yields the cooperative thread, starving the very actor it is
        // supposed to be supervising.
        await Task.yield()
        try Task.checkCancellation()

        lock.withLock {
            if seconds > 0 {
                _now.addTimeInterval(seconds)
                _monotonic += seconds
            }
        }
    }

    /// Moves the clock without pretending anyone slept — for "the socket has
    /// now been quiet for 11 seconds" style setups.
    func advance(by seconds: TimeInterval) {
        lock.withLock {
            _now.addTimeInterval(seconds)
            _monotonic += seconds
        }
    }

    func resetRecordedSleeps() {
        lock.withLock { _requestedSleeps.removeAll() }
    }
}

// MARK: - Duration bridging

nonisolated extension Duration {
    /// `Duration` has no seconds accessor; the components are whole seconds
    /// plus attoseconds.
    var asSeconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
