//
//  DataSources.swift
//  FRC Head Ref Helper
//
//  Where event data comes from.
//
//  The important correction over the first pass: these are NOT mutually
//  exclusive. A head referee at a real event routinely runs several at once,
//  because each one knows things the others do not:
//
//    • frc.events   — the official schedule, official scores and official team
//                     avatars. Only has data for official events, and for
//                     offseasons running HQ's FMS.
//    • Cheesy Arena — offseason field software. Knows the schedule, what match
//                     is queued/playing right now (over a websocket), and real
//                     team names/numbers including B-teams that appear in no
//                     official source.
//    • FRC Nexus    — the best view of queueing: which matches have been
//                     queued, and which teams are missing or running late.
//                     This is the one a head ref actually wants.
//    • The Blue Alliance — mirrors frc.events for official events, and can be
//                     written to from Cheesy Arena. Adds robot photos teams
//                     have uploaded, plus historical team data.
//
//  So the model is a capability matrix: each source is independently enabled,
//  each capability is served by the highest-priority enabled source that
//  offers it.
//

import Foundation

// MARK: - Capabilities

/// A discrete thing the app needs to know, which some sources can answer.
enum SourceCapability: String, CaseIterable, Identifiable, Hashable {
    case matchSchedule
    case liveMatchState
    case officialScores
    case queueStatus
    case teamNames
    case teamAvatars
    case robotPhotos
    case scheduleVsActual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .matchSchedule: "Match schedule"
        case .liveMatchState: "What's playing now"
        case .officialScores: "Official scores"
        case .queueStatus: "Queueing and late teams"
        case .teamNames: "Team names and numbers"
        case .teamAvatars: "Official team avatars"
        case .robotPhotos: "Robot photos"
        case .scheduleVsActual: "Scheduled vs actual start"
        }
    }
}

// MARK: - Sources

enum DataSourceKind: String, CaseIterable, Identifiable, Codable {
    case frcEvents
    case cheesyArena
    case frcNexus
    case blueAlliance

    var id: String { rawValue }

    var name: String {
        switch self {
        case .frcEvents: "frc.events"
        case .cheesyArena: "Cheesy Arena"
        case .frcNexus: "FRC Nexus"
        case .blueAlliance: "The Blue Alliance"
        }
    }

    var detail: String {
        switch self {
        case .frcEvents: "Official source of schedule, scores and avatars"
        case .cheesyArena: "Offseason FMS on the local network"
        case .frcNexus: "Queueing data (if used at your event)"
        case .blueAlliance: "Alternative to frc.events"
        }
    }

    /// What this source can answer.
    var capabilities: Set<SourceCapability> {
        switch self {
        case .frcEvents:
            [.matchSchedule, .officialScores, .teamAvatars, .teamNames, .scheduleVsActual]
        case .cheesyArena:
            [.matchSchedule, .liveMatchState, .teamNames, .scheduleVsActual]
        case .frcNexus:
            [.queueStatus, .liveMatchState]
        case .blueAlliance:
            [.matchSchedule, .teamNames, .robotPhotos, .officialScores]
        }
    }

    /// What this source is actually allowed to answer, given everything else
    /// that is switched on right now.
    ///
    /// The one rule so far: when Cheesy Arena is enabled, frc.events serves
    /// *only* team avatars. Cheesy Arena IS the field at an offseason. While it
    /// is running, frc.events is describing a different event entirely, or a
    /// stale copy of this one — its schedule, its scores and its team list all
    /// belong to somewhere else. Avatars are the exception because they are
    /// season-wide team data: they cannot disagree with the field.
    ///
    /// Deliberately kept out of `preferenceOrder(for:)`. That ranking is a
    /// constant — the fixed opinion about which source is *better* at a thing.
    /// This is a policy about what happens to be *true at this event*, and it
    /// moves whenever a toggle moves. Keeping them apart is what lets Settings
    /// say "here is the ranking, and here is why the winner was skipped."
    func servedCapabilities(given enabled: Set<DataSourceKind>) -> Set<SourceCapability> {
        if self == .frcEvents && enabled.contains(.cheesyArena) {
            return capabilities.intersection([.teamAvatars])
        }
        return capabilities
    }

    /// Why this source is being skipped for most things, in one sentence a head
    /// ref can read at 7am. A source that silently drops out is a source that
    /// gets debugged on the field instead of in the parking lot.
    func restrictionNote(given enabled: Set<DataSourceKind>) -> String? {
        if self == .frcEvents && enabled.contains(.cheesyArena) {
            return "Cheesy Arena is the field, so frc.events is used for team avatars only."
        }
        return nil
    }

    /// Caveat shown in Settings, so nobody is surprised at an offseason.
    var caveat: String? {
        switch self {
        case .frcEvents:
            "Official events only, plus offseasons running FMS."
        case .cheesyArena:
            "Needs to be on the arena's network."
        case .frcNexus:
            nil
        case .blueAlliance:
            nil
        }
    }

    /// Preference order per capability, best first. The live field server wins
    /// for anything happening right now; the official record wins for scores.
    static func preferenceOrder(for capability: SourceCapability) -> [DataSourceKind] {
        switch capability {
        case .liveMatchState: [.cheesyArena, .frcNexus]
        case .queueStatus: [.frcNexus]
        case .officialScores: [.frcEvents, .blueAlliance]
        case .teamAvatars: [.frcEvents]
        case .robotPhotos: [.blueAlliance]
        // Cheesy Arena first: at an offseason it is the only source that knows
        // about B-teams, and at an official event it will not be enabled.
        case .teamNames: [.cheesyArena, .frcEvents, .blueAlliance]
        case .matchSchedule: [.cheesyArena, .frcEvents, .blueAlliance]
        case .scheduleVsActual: [.cheesyArena, .frcEvents]
        }
    }
}

// MARK: - Configuration

/// Which sources are switched on, and the resolution of capability -> source.
@Observable
final class SourceConfiguration {
    /// Independently enabled. Several are normally on at once.
    var enabled: Set<DataSourceKind> = [.frcEvents]

    /// Cheesy Arena server address, when that source is in use.
    var arenaAddress = "10.0.100.5"

    func isEnabled(_ source: DataSourceKind) -> Bool { enabled.contains(source) }

    func toggle(_ source: DataSourceKind) {
        if enabled.contains(source) { enabled.remove(source) } else { enabled.insert(source) }
    }

    /// The source that will actually answer this capability, or nil if nothing
    /// enabled can.
    ///
    /// Two filters, in this order: the source has to be switched on, and it has
    /// to still be *allowed* to answer this given everything else that is on.
    /// The second one is what keeps a stale frc.events schedule from quietly
    /// overriding the arena that is running the matches.
    func provider(for capability: SourceCapability) -> DataSourceKind? {
        DataSourceKind.preferenceOrder(for: capability).first { source in
            enabled.contains(source)
                && source.servedCapabilities(given: enabled).contains(capability)
        }
    }

    /// Why a higher-ranked enabled source isn't the one answering this, if one
    /// was passed over. Nil when nothing was skipped, so Settings only explains
    /// itself when there is something to explain.
    func restrictionNote(for capability: SourceCapability) -> String? {
        for source in DataSourceKind.preferenceOrder(for: capability) where enabled.contains(source) {
            // The first enabled source in the ranking either wins outright…
            if source.servedCapabilities(given: enabled).contains(capability) { return nil }
            // …or it was skipped, and owes the user a reason.
            if let note = source.restrictionNote(given: enabled) { return note }
        }
        return nil
    }

    /// Capabilities no enabled source can serve — surfaced in Settings so the
    /// gap is visible before the event starts, not during it.
    var unmetCapabilities: [SourceCapability] {
        SourceCapability.allCases.filter { provider(for: $0) == nil }
    }
}

// MARK: - Cheesy Arena field state

/// The match states Cheesy Arena broadcasts over its websocket.
///
/// Mirrors `MatchState` in Team254/cheesy-arena `field/arena.go`. Kept in the
/// same order as the Go enum so the raw integer maps straight across.
enum ArenaMatchState: Int, CaseIterable, Codable {
    case preMatch = 0
    case startMatch
    case autoPeriod
    case pausePeriod
    case teleopPeriod
    case postMatch
    case timeoutActive
    case postTimeout

    var label: String {
        switch self {
        case .preMatch: "Pre-match"
        case .startMatch: "Starting"
        case .autoPeriod: "Auto"
        case .pausePeriod: "Paused"
        case .teleopPeriod: "Teleop"
        case .postMatch: "Post-match"
        case .timeoutActive: "Timeout"
        case .postTimeout: "Post-timeout"
        }
    }

    /// Whether a match is actually being played, which is what decides between
    /// "time left in this match" and "time to the next one".
    var isPlaying: Bool {
        switch self {
        case .startMatch, .autoPeriod, .pausePeriod, .teleopPeriod: true
        default: false
        }
    }

    var isTimeout: Bool { self == .timeoutActive }
}
