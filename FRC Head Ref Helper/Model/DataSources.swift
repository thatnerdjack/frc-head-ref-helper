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
        case .blueAlliance: "Alternaitve to frc.events"
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
    func provider(for capability: SourceCapability) -> DataSourceKind? {
        DataSourceKind.preferenceOrder(for: capability).first { enabled.contains($0) }
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
