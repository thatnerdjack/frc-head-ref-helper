//
//  CheesyArenaWire.swift
//  FRC Head Ref Helper
//
//  Cheesy Arena's websocket and REST payloads, exactly as they come off the
//  wire, plus the mapping into this app's model.
//
//  These types mirror Team254/cheesy-arena. Its Go structs carry no JSON tags,
//  so the field names below are the Go field names verbatim, capital letters
//  and all — `TypeOrder`, not `typeOrder`. Renaming them to Swift style would
//  need a CodingKeys block per type and would hide the one thing worth being
//  able to check at a glance: that the name here is the name on the wire.
//
//  Verified against:
//    websocket/websocket.go      — the {type, data} envelope
//    field/arena_notifiers.go    — matchLoad / matchTime / matchTiming
//    model/match.go              — the Match struct and MatchType
//    web/api.go, web/web.go      — GET /api/arena/websocket (no auth),
//                                  GET /api/matches/{type}
//

import Foundation

// MARK: - Envelope

/// Every websocket frame is `{"type": ..., "data": ...}`.
///
/// `data` is decoded separately per type rather than with an enum of all
/// payloads, because the arena sends notifier types this app does not care
/// about (sounds, lower thirds, display modes) and an unknown `type` must be a
/// no-op, not a decode failure that tears the connection down.
nonisolated struct ArenaEnvelope: Decodable, Sendable {
    let type: String
}

// MARK: - matchTime

/// `{"MatchState": 2, "MatchTimeSec": 15}`
///
/// `MatchState` is an embedded Go named-int, which marshals as a plain field.
nonisolated struct ArenaMatchTime: Decodable, Sendable {
    let MatchState: Int
    let MatchTimeSec: Int

    var state: ArenaMatchState? { ArenaMatchState(rawValue: MatchState) }
}

nonisolated struct ArenaMatchTimeFrame: Decodable, Sendable {
    let data: ArenaMatchTime
}

// MARK: - matchLoad

/// The match the field has loaded, plus who is on it.
nonisolated struct ArenaMatchLoad: Decodable, Sendable {
    let Match: ArenaMatch
    /// True when the field has loaded this match again after it was already
    /// played. Cheesy Arena reports the fact, not a count — see
    /// `CheesyArenaClient.playNumber(for:isReplay:)` for how that becomes one.
    let IsReplay: Bool?
}

nonisolated struct ArenaMatchLoadFrame: Decodable, Sendable {
    let data: ArenaMatchLoad
}

/// `model.Match`. Only the fields this app reads are declared; Decodable
/// ignores the rest, which matters because the struct carries a dozen
/// scoring and PLC fields that change between seasons.
nonisolated struct ArenaMatch: Decodable, Sendable {
    /// 0 = Test, 1 = Practice, 2 = Qualification, 3 = Playoff.
    let `Type`: Int
    /// The match number within its type — the 41 in "Q41".
    let TypeOrder: Int
    /// Scheduled start.
    let Time: String?
    /// Actual start. Go's zero time, not null, when it has not started.
    let StartedAt: String?
    let Red1: Int
    let Red2: Int
    let Red3: Int
    let Blue1: Int
    let Blue2: Int
    let Blue3: Int

    var level: MatchLevel? {
        switch `Type` {
        case 1: .practice
        case 2: .qualification
        case 3: .playoff
        // 0 is Test. A test match is not part of the event and must not
        // appear in a referee's schedule.
        default: nil
        }
    }

    var redTeams: [String] { [Red1, Red2, Red3].filter { $0 > 0 }.map(String.init) }
    var blueTeams: [String] { [Blue1, Blue2, Blue3].filter { $0 > 0 }.map(String.init) }

    var scheduledStart: Date? { ArenaTime.parse(Time) }
    var actualStart: Date? { ArenaTime.parse(StartedAt) }
}

// MARK: - /api/matches/{type}

/// The REST schedule dump wraps each match alongside its result.
nonisolated struct ArenaMatchWithResult: Decodable, Sendable {
    let Match: ArenaMatch
}

// MARK: - Time

nonisolated enum ArenaTime {
    /// Go marshals `time.Time` as RFC 3339, and marshals an *unset* time as
    /// the year-one zero value rather than as null. Treating that as a real
    /// date would put every unstarted match at the dawn of the calendar and
    /// make "minutes behind schedule" a number in the millions.
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        guard !raw.hasPrefix("0001-01-01") else { return nil }
        return iso.date(from: raw) ?? isoNoFraction.date(from: raw)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Endpoints

/// Where the arena lives. Built from the address a referee types in Settings.
nonisolated struct ArenaEndpoints: Sendable {
    let host: String
    var port: Int = 8080

    private var base: String { "\(host):\(port)" }

    /// Unauthenticated, and carries matchTiming / matchLoad / matchTime.
    var websocket: URL? { URL(string: "ws://\(base)/api/arena/websocket") }

    /// `type` is "practice", "qualification" or "playoff".
    ///
    /// Takes the name rather than a `MatchLevel` so this stays free of the app
    /// model's main-actor isolation; `ArenaLevelName` does the mapping.
    func matches(_ level: ArenaLevelName) -> URL? {
        URL(string: "http://\(base)/api/matches/\(level.rawValue)")
    }
}

/// What Cheesy Arena calls each level in `/api/matches/{type}`.
nonisolated enum ArenaLevelName: String, Sendable, CaseIterable {
    case practice, qualification, playoff

    var matchLevel: MatchLevel {
        switch self {
        case .practice: .practice
        case .qualification: .qualification
        case .playoff: .playoff
        }
    }
}
