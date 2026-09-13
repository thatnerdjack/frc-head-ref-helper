//
//  MatchActivityAttributes.swift
//  FRC Head Ref Helper — shared between the app and the widget extension
//
//  The contract for the Live Activity. A Live Activity's UI must live in a
//  WidgetKit extension while the app is what starts and updates it, so this
//  type is compiled into both targets.
//
//  Design note: the clock is carried as an END DATE, not a seconds count.
//  `Text(timerInterval:)` then ticks on its own in the widget, so the app does
//  not have to push an update every second — which matters when the phone is
//  in a pocket all day at an event.
//

#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// One team as it appears on the Live Activity: number plus the compact card
/// state ("Y", "R", "2W", "N", or empty when clear).
struct TeamChip: Codable, Hashable, Identifiable {
    let number: String
    let badge: String
    /// True when this team is on the red alliance for this match.
    let isRed: Bool

    var isFlagged: Bool { !badge.isEmpty }
    var id: String { number }
}

struct MatchActivityAttributes: ActivityAttributes {
    /// Everything that changes over the life of one match.
    struct ContentState: Codable, Hashable {
        /// "Q41", or "Q41 (replay 2)".
        var matchLabel: String
        /// "TELEOP", "NEXT MATCH", "TIMEOUT" — whatever the clock is counting.
        var stateLabel: String
        /// When the current countdown reaches zero. Nil when nothing is timed.
        var countdownEnd: Date?
        /// Drives colour: green while a match is being played, gold otherwise.
        var isMatchRunning: Bool

        var red: [TeamChip]
        var blue: [TeamChip]

        /// Teams the queueing source says have not turned up.
        var missingTeams: [String]
        /// "Queued", "On deck" … shown when a match is waiting rather than running.
        var queueLabel: String?

        var flaggedTeams: [TeamChip] { (red + blue).filter(\.isFlagged) }

        /// "8341 2W · 7460 Y" — the badge travels with the number, because
        /// "carrying a card" and "carrying two warnings" are different things
        /// and a head referee acts differently on each.
        var flaggedSummary: String {
            flaggedTeams.map { "\($0.number) \($0.badge)" }.joined(separator: " · ")
        }
    }

    /// Fixed for the life of the activity.
    var eventName: String
}
#endif
