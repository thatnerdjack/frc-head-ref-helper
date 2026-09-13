//
//  Severity.swift
//  FRC Head Ref Helper
//
//  What an entry *is* — the six things the design lets you record, plus one
//  legacy case. Colours come straight from the design's severity swatches.
//

import SwiftUI

enum Severity: String, CaseIterable, Identifiable, Codable {
    case verbalWarning = "Verbal warning"
    case yellowCard = "Yellow card"
    case redCard = "Red card"
    case disableDQ = "Disable / DQ"
    case teamNote = "Team note"
    case inspectionConcern = "Inspection concern"

    /// Foul tallies were in the first design pass and were cut in turn 2 —
    /// the note there reads "Gone: the log timeline and foul tally". Existing
    /// entries can still carry one, so the case survives for decoding, but it
    /// is deliberately absent from `composable` and hidden on the team page.
    case foulTally = "Foul tally"

    var id: String { rawValue }

    /// The six severities the compose sheet actually offers, in design order.
    static var composable: [Severity] {
        [.verbalWarning, .yellowCard, .redCard, .disableDQ, .teamNote, .inspectionConcern]
    }

    /// The full label, used in entry rows and the export.
    var label: String { rawValue }

    /// The short label on the compose sheet's severity tiles.
    var short: String {
        switch self {
        case .verbalWarning: "Verbal"
        case .yellowCard: "Yellow"
        case .redCard: "Red"
        case .disableDQ: "DQ"
        case .teamNote: "Note"
        case .inspectionConcern: "Inspection"
        case .foulTally: "Foul"
        }
    }

    var color: Color {
        switch self {
        case .verbalWarning: Color(hex: 0x8A8F98)
        case .yellowCard: Color(hex: 0xE0B93A)
        case .redCard: Color(hex: 0xD64040)
        case .disableDQ: Color(hex: 0xB04AD6)
        case .teamNote: Color(hex: 0x5A6270)
        case .inspectionConcern: Color(hex: 0xC9A227)
        case .foulTally: Color(hex: 0x6F7BD6)
        }
    }
}

/// How a team's record reads at a glance. The design shows one badge per team
/// and picks it by precedence — a red card outranks a yellow, which outranks
/// warnings, which outrank a bare note — rather than stacking them.
struct TeamBadge: Equatable {
    let text: String
    let background: Color
    let foreground: Color

    static let none = TeamBadge(text: "", background: .clear, foreground: .white)

    var isEmpty: Bool { text.isEmpty }
}
