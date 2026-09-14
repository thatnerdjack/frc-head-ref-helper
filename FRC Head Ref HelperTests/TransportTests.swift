//
//  TransportTests.swift
//  FRC Head Ref HelperTests
//
//  The two pieces of the transport layer that are pure logic, and that are
//  worth defending out loud: the backoff schedule, and the conditional-GET
//  header rules.
//
//  Neither test sleeps and neither touches the network. That is the point of
//  TimeSource — a test that proves the backoff cap is 15 seconds would take
//  over a minute of wall clock otherwise, so nobody would run it, so the
//  schedule would quietly rot.
//

import Testing
import Foundation
@testable import FRC_Head_Ref_Helper

// MARK: - Backoff schedule

@Suite("Backoff schedule")
struct BackoffPolicyTests {
    /// Jitter zeroed so the ladder itself is what's being asserted.
    private let policy = BackoffPolicy()

    @Test("Doubles from 0.5s and caps at 15s")
    func ladder() {
        let expected: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 15, 15]
        for (index, want) in expected.enumerated() {
            let got = policy.delay(forAttempt: index + 1, jitter: 0)
            #expect(abs(got - want) < 0.0001, "attempt \(index + 1) gave \(got), wanted \(want)")
        }
    }

    @Test("Jitter stays within ±20% of the nominal delay")
    func jitterBounds() {
        // Attempt 4 is nominally 4s, far enough from the cap that both
        // extremes are visible.
        #expect(policy.delay(forAttempt: 4, jitter: 1) == 4.8)
        #expect(policy.delay(forAttempt: 4, jitter: -1) == 3.2)
        #expect(policy.delay(forAttempt: 4, jitter: 0) == 4.0)
    }

    @Test("The cap is a hard ceiling, not a nominal value")
    func capIsHard() {
        // Jitter is applied and then clamped, so a capped delay never exceeds
        // 15s on the high side but can still spread downwards — which is what
        // keeps every device at the venue from reconnecting on the same tick.
        #expect(policy.delay(forAttempt: 9, jitter: 1) == 15)
        #expect(policy.delay(forAttempt: 9, jitter: -1) == 12)
    }

    @Test("Extreme attempt counts stay finite")
    func noOverflow() {
        // 2^999 is +infinity in Double, and infinity * jitter is NaN. A NaN
        // delay would be passed to Task.sleep and trap.
        let delay = policy.delay(forAttempt: 999, jitter: 0.5)
        #expect(delay.isFinite)
        #expect(delay <= 15)
    }

    @Test("Attempt 0 and below cost nothing")
    func nonPositiveAttempts() {
        #expect(policy.delay(forAttempt: 0, jitter: 0) == 0)
        #expect(policy.delay(forAttempt: -3, jitter: 0) == 0)
    }

    /// The reset rule, exercised through the clock rather than by waiting.
    @Test("A connection held for 30s resets the ladder; a shorter one does not")
    func healthyResetThreshold() {
        let clock = ManualTimeSource()
        let policy = BackoffPolicy()

        let connectedAt = clock.monotonicSeconds
        clock.advance(by: 29)
        #expect(clock.monotonicSeconds - connectedAt < policy.healthyResetAfter)

        clock.advance(by: 1)
        #expect(clock.monotonicSeconds - connectedAt >= policy.healthyResetAfter)
    }
}

// MARK: - The injectable clock itself

@Suite("Manual clock")
struct ManualTimeSourceTests {
    @Test("Sleeping advances the clock instantly and records the request")
    func sleepIsRecordedNotServed() async throws {
        let clock = ManualTimeSource()
        let started = Date()

        try await clock.sleep(seconds: 0.5)
        try await clock.sleep(seconds: 15)

        #expect(clock.requestedSleeps == [0.5, 15])
        #expect(clock.monotonicSeconds == 15.5)
        // The whole point: no real time passed.
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("Monotonic and wall-clock readings advance together but are distinct")
    func twoReadings() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ManualTimeSource(now: start)

        clock.advance(by: 42)

        #expect(clock.monotonicSeconds == 42)
        #expect(clock.now == start.addingTimeInterval(42))
    }
}

// MARK: - Conditional GET

@Suite("Conditional GET headers")
struct ConditionalGETTests {
    @Test("No validator means an unconditional GET")
    func noValidator() {
        #expect(ConditionalGET.requestHeaders(validator: nil).isEmpty)
        #expect(ConditionalGET.requestHeaders(validator: CacheValidator()).isEmpty)
    }

    @Test("An ETag is replayed verbatim, quotes and weak prefix included")
    func eTagIsVerbatim() {
        // Stripping the quotes or the W/ prefix would make the server's byte
        // comparison fail and we would never see a 304 again.
        let headers = ConditionalGET.requestHeaders(
            validator: CacheValidator(eTag: "W/\"a1b2c3\"")
        )
        #expect(headers["If-None-Match"] == "W/\"a1b2c3\"")
    }

    @Test("Last-Modified is replayed verbatim, never reformatted")
    func lastModifiedIsVerbatim() {
        let raw = "Wed, 21 Oct 2026 07:28:00 GMT"
        let headers = ConditionalGET.requestHeaders(validator: CacheValidator(lastModified: raw))
        #expect(headers["If-Modified-Since"] == raw)
    }

    @Test("Both validators are sent when both are known")
    func bothValidators() {
        let headers = ConditionalGET.requestHeaders(
            validator: CacheValidator(eTag: "\"x\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT")
        )
        #expect(headers["If-None-Match"] == "\"x\"")
        #expect(headers["If-Modified-Since"] == "Wed, 21 Oct 2026 07:28:00 GMT")
    }

    @Test("Blank validators are dropped rather than sent empty")
    func blankValidatorsDropped() {
        // `If-None-Match: ` makes some origins answer 400.
        let validator = CacheValidator(eTag: "   ", lastModified: "\n")
        #expect(validator.isEmpty)
        #expect(ConditionalGET.requestHeaders(validator: validator).isEmpty)
    }

    @Test("Conditional headers win over a hand-written base header")
    func conditionalHeadersOverrideBase() {
        let headers = ConditionalGET.requestHeaders(
            base: ["If-None-Match": "stale", "X-TBA-Auth-Key": "secret"],
            validator: CacheValidator(eTag: "\"fresh\"")
        )
        #expect(headers["If-None-Match"] == "\"fresh\"")
        // Unrelated caller headers survive.
        #expect(headers["X-TBA-Auth-Key"] == "secret")
    }

    @Test("Response header lookup is case-insensitive")
    func headerLookupIsCaseInsensitive() {
        // Servers spell these every possible way; frc.events and TBA disagree.
        let response = HTTPResponseValue(
            statusCode: 200,
            headers: ["etag": "\"1\"", "LAST-MODIFIED": "Wed, 21 Oct 2026 07:28:00 GMT"]
        )
        #expect(response.validator.eTag == "\"1\"")
        #expect(response.validator.lastModified == "Wed, 21 Oct 2026 07:28:00 GMT")
    }

    @Test("A 304 that omits validators keeps the ones we already had")
    func notModifiedKeepsStoredValidators() {
        // RFC 9110 lets a 304 omit the validators, meaning "the ones you sent
        // are still current". Dropping them would silently downgrade every
        // future poll to a full download.
        let stored = CacheValidator(eTag: "\"1\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT")
        let refreshed = ConditionalGET.refreshed(stored, with: HTTPResponseValue(statusCode: 304))
        #expect(refreshed == stored)
    }

    @Test("A 304 that rotates the ETag replaces it")
    func notModifiedRotatesETag() {
        let stored = CacheValidator(eTag: "\"1\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT")
        let refreshed = ConditionalGET.refreshed(
            stored,
            with: HTTPResponseValue(statusCode: 304, headers: ["ETag": "\"2\""])
        )
        #expect(refreshed.eTag == "\"2\"")
        // The Last-Modified the 304 did not mention is preserved.
        #expect(refreshed.lastModified == stored.lastModified)
    }
}

// MARK: - Local network probe classification

@Suite("Local network probe")
struct LocalNetworkProbeTests {
    @Test("Recognises the address ranges a field network actually uses")
    func privateRanges() {
        // Cheesy Arena's default, and the two other shapes seen in the wild.
        #expect(LocalNetworkProbe.isPrivateIPv4("10.0.100.5"))
        #expect(LocalNetworkProbe.isPrivateIPv4("192.168.1.20"))
        #expect(LocalNetworkProbe.isPrivateIPv4("172.22.11.1"))
        #expect(LocalNetworkProbe.isPrivateIPv4("169.254.1.1"))

        #expect(!LocalNetworkProbe.isPrivateIPv4("172.15.0.1"))
        #expect(!LocalNetworkProbe.isPrivateIPv4("172.32.0.1"))
        #expect(!LocalNetworkProbe.isPrivateIPv4("8.8.8.8"))
        #expect(!LocalNetworkProbe.isPrivateIPv4("thebluealliance.com"))
        #expect(!LocalNetworkProbe.isPrivateIPv4("10.0.100"))
        #expect(!LocalNetworkProbe.isPrivateIPv4("10.0.100.999"))
    }

    @Test("Every verdict carries advice somebody at the scoring table can act on")
    func adviceIsPresent() {
        let verdicts: [LocalNetworkVerdict] = [
            .reachable, .refused, .noNetwork,
            .likelyPermissionDenied, .likelyServerUnreachable, .notApplicable
        ]
        for verdict in verdicts {
            #expect(!verdict.advice.isEmpty)
        }
        // The whole reason this probe exists is that these two are
        // indistinguishable from the socket's point of view, so they must not
        // read the same to the user either.
        #expect(LocalNetworkVerdict.likelyPermissionDenied.advice
                != LocalNetworkVerdict.likelyServerUnreachable.advice)
    }
}

// MARK: - Connection state

@Suite("Connection state")
struct ConnectionStateTests {
    @Test("Only .connected reads as connected")
    func isConnected() {
        #expect(ConnectionState.connected(since: Date()).isConnected)
        #expect(!ConnectionState.idle.isConnected)
        #expect(!ConnectionState.offline.isConnected)
        #expect(!ConnectionState.connecting(attempt: 1).isConnected)
        #expect(!ConnectionState.waiting(retryAt: Date(), attempt: 2, reason: "x").isConnected)
        #expect(!ConnectionState.failed(reason: "x").isConnected)
    }
}
