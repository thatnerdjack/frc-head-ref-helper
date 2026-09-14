//
//  Notebook+Clocks.swift
//  FRC Head Ref Helper
//
//  Every clock the app reads out: the timeout countdown, the wait for the next
//  match, and the unofficial estimate of time left in the match on the field.
//
//  All of them are derived from `now`, which ticks once a second, and from
//  fixed dates rather than decrementing counters — a counter is wrong the
//  moment the app is suspended.
//

import Foundation

extension Notebook {

    // MARK: - Clock labels

    /// mm:ss for a second count, clamped at zero.
    func clockText(_ seconds: Int) -> String { clock(seconds) }

    private func clock(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 60):\(String(format: "%02d", clamped % 60))"
    }

    /// Seconds left on the timeout clock, or 0 when none is running.
    var breakSecondsRemaining: Int {
        guard let timeoutEndsAt else { return 0 }
        return Int(max(0, timeoutEndsAt.timeIntervalSince(now)))
    }

    var breakClock: String { clock(breakSecondsRemaining) }

    /// Seconds until the next match is scheduled to start.
    var secondsToNextMatch: Int {
        guard let start = nextMatch?.scheduledStart else { return 0 }
        return Int(start.timeIntervalSince(now))
    }

    var nextMatchClock: String { clock(secondsToNextMatch) }

    /// An UNOFFICIAL estimate of time left in the match on the field, derived
    /// from when it actually started. FMS is the only authority on match time;
    /// this is close enough to answer "how long have I got", which is all the
    /// watch is being asked.
    var matchSecondsRemaining: Int? {
        guard let match = currentMatch, let started = match.actualStart else { return nil }
        let remaining = Self.matchLength - now.timeIntervalSince(started)
        guard remaining > -30 else { return nil }   // stale: match long over
        return Int(max(0, remaining))
    }

    var isMatchRunning: Bool {
        if let arenaState { return arenaState.isPlaying }
        return matchSecondsRemaining.map { $0 > 0 } ?? false
    }

    /// The single clock the watch shows: time left in the match if one is
    /// running, otherwise the countdown to whatever happens next.
    var primaryClock: (label: String, value: String) {
        if fieldState == .paused || arenaState?.isTimeout == true {
            return ("TIMEOUT", breakClock)
        }
        if isMatchRunning, let remaining = matchSecondsRemaining {
            return (arenaState?.label.uppercased() ?? "MATCH", clock(remaining))
        }
        return ("NEXT MATCH", nextMatchClock)
    }

    /// "NEXT IN 4:12" while play is running, "AFTER THE BREAK" when paused.
    var nextMatchLeadLabel: String {
        fieldState == .paused ? "AFTER THE BREAK" : "NEXT IN \(nextMatchClock)"
    }
}
