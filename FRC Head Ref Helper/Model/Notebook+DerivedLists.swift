//
//  Notebook+DerivedLists.swift
//  FRC Head Ref Helper
//
//  The lists the Teams tab and the event picker draw, and the subject the
//  team page and compose sheet are pointed at.
//

import Foundation

extension Notebook {

    // MARK: - Derived lists

    /// The subject the team page and compose sheet act on, defaulting to the
    /// first team on the field so nothing is ever nil.
    var activeSubject: String {
        selectedSubject ?? currentMatch?.onField.first ?? "8341"
    }

    var isAllianceSubject: Bool { activeSubject.hasPrefix("Alliance ") }

    func teamRows() -> [Team] {
        let needle = teamQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return SampleEvent.teams }
        return SampleEvent.teams.filter {
            $0.number.contains(needle) || $0.name.lowercased().contains(needle)
        }
    }

    /// Only alliances that actually carry an entry appear in the Teams list —
    /// otherwise all eight would sit above the teams doing nothing.
    func allianceRows() -> [Alliance] {
        let needle = teamQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return SampleEvent.alliances.filter { alliance in
            guard entries.contains(where: { $0.subject == alliance.label }) else { return false }
            guard !needle.isEmpty else { return true }
            return String(alliance.seed) == needle || alliance.label.lowercased().contains(needle)
        }
    }

    func eventRows() -> [RefEvent] {
        let needle = eventQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return SampleEvent.events }
        return SampleEvent.events.filter {
            $0.name.lowercased().contains(needle) || $0.code.tbaKey.contains(needle)
        }
    }
}
