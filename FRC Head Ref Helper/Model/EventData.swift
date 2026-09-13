//
//  EventData.swift
//  FRC Head Ref Helper
//
//  Teams, alliances, matches and the event itself.
//
//  Match identity is deliberately richer than "Q41". Matches get replayed
//  after an ARENA FAULT and they do not always run in schedule order, so a
//  match is identified by level + number + which PLAY it is. An entry logged
//  during the first running of Q41 must stay attached to that play even after
//  Q41 is replayed.
//

import SwiftUI

// MARK: - Event identity

/// An event code, accepted in either of the two spellings a head referee is
/// likely to have to hand.
///
/// The Blue Alliance uses a season-prefixed key (`2026cada`); frc.events takes
/// the season and the bare code separately (`2026` + `CADA`). Both are the same
/// event, so this parses either and can emit both.
struct EventCode: Hashable, Codable {
    let season: Int
    /// Lowercase, no season prefix.
    let code: String

    /// The Blue Alliance event key.
    var tbaKey: String { "\(season)\(code)" }

    /// What frc.events expects in its path.
    var frcEventsCode: String { code.uppercased() }

    var display: String { tbaKey }

    /// Accepts "2026cada", "2026CADA", or a bare "cada" (which assumes
    /// `defaultSeason`). Returns nil for anything that is not plausibly a code.
    init?(_ raw: String, defaultSeason: Int = EventCode.currentSeason) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let match = trimmed.wholeMatch(of: /(\d{4})([a-z0-9]{2,10})/) {
            season = Int(match.1) ?? defaultSeason
            code = String(match.2)
        } else if trimmed.wholeMatch(of: /[a-z][a-z0-9]{1,9}/) != nil {
            season = defaultSeason
            code = trimmed
        } else {
            return nil
        }
    }

    /// The competition season. Kick-off is in January, so a date in the back
    /// half of a calendar year already belongs to the next season's offseason.
    static var currentSeason: Int {
        Calendar.current.component(.year, from: .now)
    }
}

struct RefEvent: Identifiable, Hashable {
    let code: EventCode
    let name: String
    let when: String
    let teamCount: String

    var id: String { code.tbaKey }
}

// MARK: - Teams and alliances

struct Team: Identifiable, Hashable {
    let number: String
    let name: String

    /// Offseason B-teams (e.g. "254B") exist in Cheesy Arena but in no official
    /// source, which is why team names are worth pulling from the field server.
    var isBTeam: Bool { number.last?.isLetter ?? false }

    var id: String { number }
}

struct Alliance: Identifiable, Hashable {
    let seed: Int
    let teams: [String]

    var id: Int { seed }
    var label: String { "Alliance \(seed)" }
    var teamList: String { teams.joined(separator: "  ") }
}

enum AllianceColor {
    case red, blue

    var bar: Color { self == .red ? RefColor.redBar : RefColor.blueBar }
    var text: Color { self == .red ? RefColor.redText : RefColor.blueText }
    var watchBar: Color { self == .red ? RefColor.redWatch : RefColor.blueWatch }
    var name: String { self == .red ? "Red" : "Blue" }
}

// MARK: - Matches

enum MatchLevel: String, Codable, Hashable {
    case practice, qualification, playoff

    var prefix: String {
        switch self {
        case .practice: "P"
        case .qualification: "Q"
        case .playoff: "M"
        }
    }
}

/// Identifies one PLAY of a match. `play` is 1 for the first running and
/// increments on each replay, so a replayed Q41 is a distinct key from the
/// original and entries never silently merge across them.
struct MatchKey: Hashable, Codable {
    let level: MatchLevel
    let number: Int
    var play: Int = 1

    /// "Q41", or "Q41 (replay 2)" once it has been run again.
    var display: String {
        play == 1 ? short : "\(short) (replay \(play))"
    }

    /// "Q41" — always the bare label, for tight spaces like the watch.
    var short: String { "\(level.prefix)\(number)" }

    /// Stable string form for persistence: "Q41.1".
    var storageKey: String { "\(level.prefix)\(number).\(play)" }
}

/// Where a match is in the queueing pipeline. FRC Nexus is the source that
/// actually knows this, and it is the thing a head ref is asked about most.
enum QueueStatus: String, Codable, CaseIterable {
    case notQueued, queuing, queued, onDeck, onField, played

    var label: String {
        switch self {
        case .notQueued: "Not queued"
        case .queuing: "Queuing"
        case .queued: "Queued"
        case .onDeck: "On deck"
        case .onField: "On field"
        case .played: "Played"
        }
    }

    var color: Color {
        switch self {
        case .notQueued: .white.opacity(0.4)
        case .queuing, .queued: RefColor.gold
        case .onDeck: RefColor.goldPale
        case .onField: RefColor.live
        case .played: .white.opacity(0.35)
        }
    }
}

struct Match: Identifiable, Hashable {
    let key: MatchKey
    let red: [String]
    let blue: [String]

    /// When the schedule says it should start.
    var scheduledStart: Date?
    /// When it actually started. The gap between the two is how far behind the
    /// event is running, which both frc.events and Cheesy Arena can report.
    var actualStart: Date?

    var queueStatus: QueueStatus = .notQueued
    /// Teams FRC Nexus reports as missing or late for this match.
    var missingTeams: [String] = []

    var id: String { key.storageKey }

    var onField: [String] { red + blue }

    func color(of team: String) -> AllianceColor {
        red.contains(team) ? .red : .blue
    }

    /// Positive when running late. Nil until both times are known.
    var minutesBehindSchedule: Int? {
        guard let scheduledStart, let actualStart else { return nil }
        return Int(actualStart.timeIntervalSince(scheduledStart) / 60)
    }

    var isReplay: Bool { key.play > 1 }
}

// MARK: - Event phase

/// Where the event is in its day.
///
/// Derived, never set by hand: the field software already knows, because it
/// knows what match is about to be played. A playoff match on the field means
/// alliances exist, which is the only thing this actually gates.
enum EventPhase: String {
    case qualification, playoff

    var label: String {
        switch self {
        case .qualification: "Qualifications"
        case .playoff: "Playoffs"
        }
    }

    /// Alliance-wide entries only exist once there are alliances to attach
    /// them to.
    var alliancesExist: Bool { self == .playoff }

    /// The stage implied by whatever match is on or next. Practice and
    /// qualification matches both mean "no alliances yet".
    init(matchLevel: MatchLevel?) {
        self = matchLevel == .playoff ? .playoff : .qualification
    }
}

// MARK: - Match sources for display

struct ArenaServer: Identifiable, Hashable {
    let address: String
    let detail: String
    let isReachable: Bool

    var id: String { address }
}

// MARK: - The sample event

enum SampleEvent {
    static let code = EventCode("2026cada") ?? EventCode("2026cada", defaultSeason: 2026)!

    static let teams: [Team] = [
        Team(number: "8341", name: "Ridge Robotics"),
        Team(number: "6812", name: "Gearhawks"),
        Team(number: "9021", name: "Copper Canyon"),
        Team(number: "5883", name: "Blue Ridge Bots"),
        Team(number: "7460", name: "Nightingale"),
        Team(number: "4055", name: "Ferrous"),
        Team(number: "3129", name: "Ironwood"),
        Team(number: "8802", name: "Sagebrush"),
        Team(number: "6440", name: "Lakeshore"),
        Team(number: "5510", name: "Foundry"),
    ]

    static let alliances: [Alliance] = [
        Alliance(seed: 1, teams: ["8341", "5883", "6440"]),
        Alliance(seed: 2, teams: ["7460", "3129", "5510"]),
        Alliance(seed: 3, teams: ["6812", "8802", "9021"]),
        Alliance(seed: 4, teams: ["4055", "2471", "3648"]),
        Alliance(seed: 5, teams: ["5024", "7712", "6193"]),
        Alliance(seed: 6, teams: ["4907", "8156", "2930"]),
        Alliance(seed: 7, teams: ["6529", "3405", "9114"]),
        Alliance(seed: 8, teams: ["5842", "7038", "4110"]),
    ]

    /// The schedule, in SCHEDULE order. Play order is whatever actually
    /// happens — see `Notebook.matchesInPlayOrder`.
    static func schedule(now: Date = .now) -> [Match] {
        [
            Match(key: MatchKey(level: .qualification, number: 39),
                  red: ["4055", "5510", "6440"], blue: ["9021", "3129", "8802"],
                  scheduledStart: now.addingTimeInterval(-32 * 60),
                  actualStart: now.addingTimeInterval(-28 * 60),
                  queueStatus: .played),
            Match(key: MatchKey(level: .qualification, number: 40),
                  red: ["7460", "8802", "5883"], blue: ["6812", "6440", "4055"],
                  scheduledStart: now.addingTimeInterval(-16 * 60),
                  actualStart: now.addingTimeInterval(-11 * 60),
                  queueStatus: .played),
            Match(key: MatchKey(level: .qualification, number: 41),
                  red: ["8341", "6812", "9021"], blue: ["5883", "7460", "4055"],
                  scheduledStart: now.addingTimeInterval(-5 * 60),
                  actualStart: now.addingTimeInterval(-1 * 60),
                  queueStatus: .onField),
            Match(key: MatchKey(level: .qualification, number: 42),
                  red: ["3129", "8802", "6440"], blue: ["5510", "7460", "8341"],
                  scheduledStart: now.addingTimeInterval(4 * 60),
                  queueStatus: .queued,
                  missingTeams: ["6440"]),
            Match(key: MatchKey(level: .qualification, number: 43),
                  red: ["9021", "5024", "4907"], blue: ["6812", "5883", "6529"],
                  scheduledStart: now.addingTimeInterval(12 * 60),
                  queueStatus: .queuing,
                  missingTeams: ["5024", "4907"]),
            Match(key: MatchKey(level: .qualification, number: 44),
                  red: ["8341", "3129", "7712"], blue: ["4055", "8802", "5842"],
                  scheduledStart: now.addingTimeInterval(20 * 60),
                  queueStatus: .notQueued),
        ]
    }

    static let events: [RefEvent] = [
        RefEvent(code: EventCode("2026cada")!, name: "Capital District", when: "Mar 12–14 · Sacramento, CA", teamCount: "40 teams"),
        RefEvent(code: EventCode("2026casd")!, name: "San Diego Regional", when: "Mar 19–21 · San Diego, CA", teamCount: "52 teams"),
        RefEvent(code: EventCode("2026orore")!, name: "Oregon State Championship", when: "Apr 2–4 · Portland, OR", teamCount: "48 teams"),
        RefEvent(code: EventCode("2026week0")!, name: "Week 0 Offseason", when: "Feb 21 · Manchester, NH", teamCount: "24 teams"),
        RefEvent(code: EventCode("2026chzy")!, name: "Chezy Champs", when: "Sep 26–27 · San Jose, CA", teamCount: "36 teams"),
    ]

    static let recentServers: [ArenaServer] = [
        ArenaServer(address: "10.0.100.5", detail: "Chezy Champs · last Saturday", isReachable: true),
        ArenaServer(address: "192.168.1.42", detail: "Week 0 · February", isReachable: false),
    ]

    static func team(_ number: String) -> Team? {
        teams.first { $0.number == number }
    }

    static func alliance(labelled label: String) -> Alliance? {
        alliances.first { $0.label == label }
    }
}
