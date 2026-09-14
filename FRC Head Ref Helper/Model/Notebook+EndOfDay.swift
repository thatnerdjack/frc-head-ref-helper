//
//  Notebook+EndOfDay.swift
//  FRC Head Ref Helper
//
//  The day-complete tallies, and the two lists worth reading during a break:
//  what follows the teams into tomorrow, and what is still unfinished.
//

import Foundation

extension Notebook {

    // MARK: - End of day

    var entriesToday: Int { entries.count }
    var cardsIssued: Int {
        entries.filter { [.yellowCard, .redCard, .disableDQ].contains($0.severity) }.count
    }

    /// Teams whose state follows them into tomorrow — anything carrying a badge.
    var carriesIntoTomorrow: [Team] {
        SampleEvent.teams.filter { !badge(for: $0.number).isEmpty }
    }

    /// Entries saved without a rule attached, surfaced during a break so they
    /// can be finished while there is a minute to do it.
    var unfinishedEntries: [RefEntry] {
        entries.filter { $0.ruleCode.isEmpty }
    }
}
