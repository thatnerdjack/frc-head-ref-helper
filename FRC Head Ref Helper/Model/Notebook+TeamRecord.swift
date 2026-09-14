//
//  Notebook+TeamRecord.swift
//  FRC Head Ref Helper
//
//  How a pile of entries reads as one team's record: the tallies, the single
//  badge, and the escalation hint.
//
//  This is the part of the notebook a head ref is actually judged on, so it
//  stays in one testable place rather than inside a view. `import SwiftUI` is
//  here because a badge carries its own colours.
//

import Foundation
import SwiftUI

extension Notebook {

    // MARK: - Reading a team's record

    struct Counts {
        var warnings = 0
        var yellow = 0
        var red = 0
        var notes = 0
        var total = 0
    }

    func counts(for subject: String) -> Counts {
        var counts = Counts()
        for entry in entries where entry.subject == subject {
            counts.total += 1
            switch entry.severity {
            case .verbalWarning: counts.warnings += 1
            case .yellowCard: counts.yellow += 1
            case .redCard, .disableDQ: counts.red += 1
            case .teamNote, .inspectionConcern: counts.notes += 1
            case .foulTally: break
            }
        }
        return counts
    }

    /// The single badge shown for a team. Precedence, not accumulation: a team
    /// carrying a red card reads "RED CARD", never "RED CARD + 2 WARNINGS".
    func badge(for subject: String) -> TeamBadge {
        let counts = counts(for: subject)
        if counts.red > 0 {
            return TeamBadge(text: "RED CARD", background: Color(hex: 0xD64040), foreground: .white)
        }
        if counts.yellow > 0 {
            return TeamBadge(text: "YELLOW", background: Color(hex: 0xE0B93A), foreground: Color(hex: 0x17140A))
        }
        if counts.warnings > 0 {
            let text = "\(counts.warnings) \(counts.warnings > 1 ? "WARNINGS" : "WARNING")"
            return TeamBadge(text: text, background: RefColor.gold, foreground: Color(hex: 0x17140A))
        }
        if counts.notes > 0 {
            return TeamBadge(text: "NOTE", background: Color.white.opacity(0.18), foreground: .white)
        }
        return .none
    }

    /// The compact badge the watch shows, where there is no room to spell it
    /// out: "R", "Y", "2W", "N".
    func shortBadge(for subject: String) -> String {
        let counts = counts(for: subject)
        if counts.red > 0 { return "R" }
        if counts.yellow > 0 { return "Y" }
        if counts.warnings > 0 { return "\(counts.warnings)W" }
        if counts.notes > 0 { return "N" }
        return ""
    }

    /// The escalation hint. Two verbal warnings for the *same rule* is the
    /// point the manual starts pointing at a yellow card, so that — and only
    /// that — is what raises a hint. Different rules don't stack.
    func escalationHint(for subject: String, in list: [RefEntry]? = nil) -> String? {
        guard escalationHintsEnabled else { return nil }
        let source = list ?? entries
        var byRule: [String: Int] = [:]
        for entry in source where entry.subject == subject && entry.severity == .verbalWarning {
            byRule[entry.ruleCode, default: 0] += 1
        }
        guard let (code, count) = byRule.first(where: { $0.value >= 2 }) else { return nil }
        return "\(subject) has \(count) verbal warnings for \(code) at this event. "
    }

    func entries(for subject: String) -> [RefEntry] {
        // Foul tallies are data-only since turn 2 of the design dropped them
        // from the UI; they stay out of the team page.
        entries.filter { $0.subject == subject && $0.severity != .foulTally }
    }
}
