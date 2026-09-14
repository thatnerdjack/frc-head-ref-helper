//
//  Notebook+Export.swift
//  FRC Head Ref Helper
//
//  The two things a head ref hands over at the end of the day: the readable
//  report, and the archive.
//
//  Both read `entries`, which is already scoped to the open event by
//  `reload()`, so neither has to think about scoping.
//

import Foundation

extension Notebook {

    // MARK: - Export

    var exportSummary: String {
        let subjects = Set(entries.map(\.subject)).count
        return "\(entries.count) entries across \(subjects) teams."
    }

    /// The report a head ref emails at the end of the day. Grouped the way the
    /// design's preview shows it: cards first, then warnings, then notes.
    var exportMarkdown: String {
        var lines = [
            "# \(eventName) — head referee log",
            "\(eventCode.tbaKey) · \(qualsPlayed) of \(qualsTotal) quals played · exported \(Self.timeFormatter.string(from: .now))",
            "",
            "## Cards",
        ]

        let cards = entries.filter { [.yellowCard, .redCard, .disableDQ].contains($0.severity) }
        lines += cards.isEmpty
            ? ["- none"]
            : cards.map { "- \($0.subject) — \($0.severity.short.lowercased()), \($0.matchLabel), \($0.ruleDisplay)" }

        lines += ["", "## Verbal warnings"]
        let warnings = entries.filter { $0.severity == .verbalWarning }
        lines += warnings.isEmpty
            ? ["- none"]
            : warnings.map { "- \($0.subject) — \($0.ruleDisplay), \($0.matchLabel)" }

        lines += ["", "## Notes"]
        let notes = entries.filter { $0.severity == .teamNote || $0.severity == .inspectionConcern }
        lines += notes.isEmpty
            ? ["- none"]
            : notes.map { "- \($0.subject) — \($0.note.isEmpty ? $0.ruleDisplay : $0.note)" }

        return lines.joined(separator: "\n")
    }

    /// The archive format. Quotes are doubled so notes containing commas or
    /// quotation marks survive the round trip into a spreadsheet.
    var exportCSV: String {
        func escape(_ field: String) -> String {
            "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        let header = "subject,severity,rule,match,time,note"
        let rows = entries.map { entry in
            [entry.subject, entry.severity.label, entry.ruleDisplay,
             entry.matchLabel, entry.timeLabel, entry.note]
                .map(escape)
                .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }
}
