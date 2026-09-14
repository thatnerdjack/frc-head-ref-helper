//
//  RefEntry.swift
//  FRC Head Ref Helper
//
//  One line in the notebook: who, which rule, what happened, and what you saw.
//
//  Persisted with SwiftData so entries survive the app being backgrounded or
//  the phone dying mid-event. The schema is deliberately CloudKit-compatible
//  — every property has a default and nothing is uniqued — because the app
//  carries an iCloud container, which is how the design's "stays on this
//  phone and on your watch" sync happens. Nothing here goes to FMS.
//

import Foundation
import SwiftData

@Model
final class RefEntry {
    /// Our own identifier. Not a SwiftData unique constraint: CloudKit-backed
    /// stores don't allow those.
    var entryID: UUID = UUID()

    /// The event this entry belongs to, as an `EventCode.tbaKey` ("2026cada").
    ///
    /// Without this every count, badge, escalation hint and export pooled every
    /// entry ever written across every event — so a card from last week's
    /// offseason showed up against a team today. Empty means "unfiled": an
    /// entry written by a build from before scoping existed.
    ///
    /// Defaulted and non-unique, which is what a CloudKit-backed store requires.
    var eventKey: String = ""

    /// A team number ("8341") or an alliance label ("Alliance 4"). Alliance
    /// entries are how the design applies a playoff card to all three teams
    /// at once.
    var subject: String = ""

    /// `Severity.rawValue`. Stored as a string so an entry written by a newer
    /// build with an unknown severity still loads instead of failing to decode.
    var severityRaw: String = Severity.verbalWarning.rawValue

    var ruleCode: String = ""

    /// Which PLAY of which match this happened in, e.g. "Q41.1". Stored rather
    /// than just "Q41" so an entry stays attached to the original running of a
    /// match after an ARENA FAULT replay creates a second play of it.
    var matchKeyRaw: String = ""

    /// How the match read when the entry was written, e.g. "Q41" or
    /// "Q41 (replay 2)". Denormalised on purpose: the label a referee saw when
    /// they wrote the entry is what should appear in the report later.
    var matchLabel: String = "—"

    /// Wall-clock label as shown in the design ("14:22"). Kept alongside
    /// `createdAt` because the reports referees hand in quote match time.
    var timeLabel: String = ""

    var note: String = ""
    var createdAt: Date = Date.now

    init(
        subject: String,
        severity: Severity,
        ruleCode: String,
        eventKey: String = "",
        matchKeyRaw: String = "",
        matchLabel: String = "—",
        timeLabel: String = "",
        note: String = "",
        createdAt: Date = .now
    ) {
        self.entryID = UUID()
        self.eventKey = eventKey
        self.subject = subject
        self.severityRaw = severity.rawValue
        self.ruleCode = ruleCode
        self.matchKeyRaw = matchKeyRaw
        self.matchLabel = matchLabel
        self.timeLabel = timeLabel
        self.note = note
        self.createdAt = createdAt
    }

    /// Falls back to a team note rather than crashing if an unrecognised
    /// severity ever comes back from the store.
    var severity: Severity {
        get { Severity(rawValue: severityRaw) ?? .teamNote }
        set { severityRaw = newValue.rawValue }
    }

    /// "G410 · Pinning"
    var ruleDisplay: String { RuleCatalog.displayName(for: ruleCode) }

    var isAllianceEntry: Bool { subject.hasPrefix("Alliance ") }
}

// MARK: - Seeding

extension RefEntry {
    /// The five entries the design ships with, so a fresh install opens on the
    /// screens as drawn — 8341 mid-escalation on G410, 7460 already carded.
    /// Delete this (and the call in `Notebook.seedIfNeeded`) once the app is
    /// reading a real event.
    static func sampleEntries() -> [RefEntry] {
        [
            // 8341 twice on G418 is the escalation case: two verbal warnings
            // for the same rule is where the manual points at a yellow.
            RefEntry(subject: "8341", severity: .verbalWarning, ruleCode: "G418",
                     eventKey: SampleEvent.code.tbaKey,
                     matchKeyRaw: "Q39.1", matchLabel: "Q39", timeLabel: "14:22",
                     note: "Held 5883 on the wall past the count. Told the drive coach."),
            RefEntry(subject: "4055", severity: .verbalWarning, ruleCode: "G413",
                     eventKey: SampleEvent.code.tbaKey,
                     matchKeyRaw: "Q38.1", matchLabel: "Q38", timeLabel: "14:11",
                     note: "Over-extended reaching across the BUMP."),
            RefEntry(subject: "8341", severity: .verbalWarning, ruleCode: "G418",
                     eventKey: SampleEvent.code.tbaKey,
                     matchKeyRaw: "Q37.1", matchLabel: "Q37", timeLabel: "14:05"),
            RefEntry(subject: "7460", severity: .yellowCard, ruleCode: "G420",
                     eventKey: SampleEvent.code.tbaKey,
                     matchKeyRaw: "Q36.1", matchLabel: "Q36", timeLabel: "13:48",
                     note: "Third contact with a climbing opponent after two warnings."),
            RefEntry(subject: "5883", severity: .teamNote, ruleCode: "R107",
                     eventKey: SampleEvent.code.tbaKey,
                     matchLabel: "—", timeLabel: "13:30",
                     note: "Measures over when the elevator tilts forward. Watch it in playoffs."),
        ]
    }
}
