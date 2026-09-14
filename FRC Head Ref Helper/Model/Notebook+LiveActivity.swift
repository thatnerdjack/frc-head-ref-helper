//
//  Notebook+LiveActivity.swift
//  FRC Head Ref Helper
//
//  The notebook's half of the Live Activity: turning the current state into a
//  `ContentState` and handing it to `LiveActivityController`.
//
//  The whole file is one `#if canImport(ActivityKit) && os(iOS)` pair. The
//  `#else` stubs are not optional — `syncLiveActivity()` is called from the
//  clock tick and from the watch toggle, both of which compile on watchOS,
//  where ActivityKit is not available.
//

import Foundation

extension Notebook {

    // MARK: - Live Activity

    #if canImport(ActivityKit) && os(iOS)
    /// The Live Activity's view of the world. Built from the same values the
    /// Now screen and the watch use, so the three never disagree.
    var liveActivityState: MatchActivityAttributes.ContentState {
        let showingCurrent = isMatchRunning && currentMatch != nil
        let match = showingCurrent ? currentMatch : (nextMatch ?? currentMatch)

        func chips(_ teams: [String], isRed: Bool) -> [TeamChip] {
            teams.map { TeamChip(number: $0, badge: shortBadge(for: $0), isRed: isRed) }
        }

        return MatchActivityAttributes.ContentState(
            matchLabel: match?.key.display ?? "—",
            matchShort: match?.key.short ?? "—",
            stateLabel: primaryClock.label,
            countdownEnd: countdownEnd,
            isMatchRunning: showingCurrent,
            red: chips(match?.red ?? [], isRed: true),
            blue: chips(match?.blue ?? [], isRed: false),
            missingTeams: showingCurrent ? [] : (match?.missingTeams ?? []),
            queueLabel: showingCurrent ? nil : match?.queueStatus.label
        )
    }

    /// When the clock currently being shown reaches zero.
    /// When the clock currently being shown reaches zero.
    ///
    /// Every branch returns a FIXED date, never one derived from `now`.
    /// `now + remaining` looks equivalent but drifts by the truncated
    /// fractional second on every tick, so the `ContentState` hash changed
    /// once a second and `LiveActivityController`'s signature check — the
    /// whole reason the widget ticks itself — never matched. The result was
    /// an ActivityKit push every second, all day.
    private var countdownEnd: Date? {
        let end: Date?
        if fieldState == .paused || arenaState?.isTimeout == true {
            end = timeoutEndsAt
        } else if isMatchRunning, matchSecondsRemaining != nil,
                  let started = currentMatch?.actualStart {
            end = started.addingTimeInterval(Self.matchLength)
        } else {
            end = nextMatch?.scheduledStart
        }

        // A countdown that has already run out is not a countdown, and handing
        // one to the widget is not a cosmetic problem: both Live Activity
        // surfaces build `Date.now...end`, and `ClosedRange` preconditions
        // lower <= upper, so a past date traps and takes the extension down.
        // Nil is already the "nothing is timed" case the widget draws, so this
        // degrades to the honest state rather than inventing a clock.
        guard let end, end > now else { return nil }
        return end
    }

    func syncLiveActivity() {
        LiveActivityController.shared.sync(eventName: eventName,
                                           state: liveActivityState,
                                           enabled: watchEnabled)
    }

    /// Called when the user turns the feature off, or the event ends.
    func stopLiveActivity() { LiveActivityController.shared.end() }
    #else
    func syncLiveActivity() {}
    func stopLiveActivity() {}
    #endif
}
