//
//  RuleCatalog.swift
//  FRC Head Ref Helper
//
//  The rule list the compose sheet searches.
//
//  These are the REAL rules, extracted from the 2026 REBUILT game manual
//  (Resources/Rules2026.json) — code, headline, section, full statement and
//  the manual's stated violation. Shipping them as a bundled JSON rather than
//  a Swift literal keeps compile times sane and means updating for a new Team
//  Update is a matter of replacing one file.
//

import Foundation

struct Rule: Identifiable, Hashable, Decodable {
    let code: String        // G418
    let title: String       // There's a 3-count on PINS
    let section: String     // Opponent Interaction
    let statement: String   // the full rule text
    let violation: String   // "MINOR FOUL, and for every 3 seconds…"

    var id: String { code }

    /// G, R, I, T, E or C.
    var category: Character { code.first ?? "G" }

    /// What the manual says this violation carries, mapped onto the severities
    /// the notebook records. Used to preselect the severity when a rule is
    /// picked — the head ref can always override it, but the common case is
    /// the one the manual already names.
    var suggestedSeverity: Severity? {
        let text = violation.uppercased()
        // Order matters: "VERBAL WARNING. YELLOW CARD if subsequent" should
        // suggest the first-offence outcome, not the escalated one.
        if text.hasPrefix("VERBAL WARNING") { return .verbalWarning }
        if text.contains("DISQUALIFIED") || text.contains("DISABLED") { return .disableDQ }
        if text.hasPrefix("RED CARD") { return .redCard }
        if text.hasPrefix("YELLOW CARD") { return .yellowCard }
        if text.contains("RED CARD") { return .redCard }
        if text.contains("YELLOW CARD") { return .yellowCard }
        return nil
    }
}

/// The rule-book section a rule belongs to. The 2026 manual uses G (game),
/// R (robot construction), I (inspection), T (tournament), E (event) and
/// C (championship) — there is no H series.
enum RuleCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case game = "G"
    case robot = "R"
    case inspection = "I"
    case tournament = "T"
    case event = "E"
    case championship = "C"

    var id: String { rawValue }

    /// Short label for the segmented control — single letters, because seven
    /// full words will not fit across a phone.
    var short: String { rawValue }

    var fullName: String {
        switch self {
        case .all: "All rules"
        case .game: "Game (G)"
        case .robot: "Robot (R)"
        case .inspection: "Inspection (I)"
        case .tournament: "Tournament (T)"
        case .event: "Event (E)"
        case .championship: "Championship (C)"
        }
    }

    func matches(_ rule: Rule) -> Bool {
        self == .all || rule.category == rawValue.first
    }
}

enum RuleCatalog {
    private struct Payload: Decodable {
        let manualSeason: Int
        let manualGame: String
        let teamUpdate: Int
        let rules: [Rule]
    }

    private static let payload: Payload = {
        guard let url = Bundle.main.url(forResource: "Rules2026", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            // An empty catalogue is survivable — the app still logs entries,
            // it just cannot offer rule search — so this does not trap.
            assertionFailure("Rules2026.json missing or unreadable")
            return Payload(manualSeason: 2026, manualGame: "", teamUpdate: 0, rules: [])
        }
        return decoded
    }()

    static var all: [Rule] { payload.rules }

    /// "2026 REBUILT presented by Haas · Team Update 22"
    static var manualVersion: String {
        "\(payload.manualSeason) \(payload.manualGame) · Team Update \(payload.teamUpdate)"
    }

    static var teamUpdate: Int { payload.teamUpdate }

    private static let byCode: [String: Rule] = {
        Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    static func rule(for code: String) -> Rule? { byCode[code] }

    /// The rule a head referee reaches for most often, used as the compose
    /// sheet's default. Pinning is the classic repeat-offender call.
    static let defaultRuleCode = "G418"

    /// A short label for an entry row: "G418 · There's a 3-count on PINS".
    static func displayName(for code: String) -> String {
        guard let rule = rule(for: code) else { return code }
        return "\(code) · \(rule.title)"
    }

    static func shortName(for code: String) -> String {
        rule(for: code)?.title ?? code
    }

    // MARK: - Search

    /// Ranks rules against a query: an exact code beats a code prefix, which
    /// beats a code substring, then the headline, then the rule's own text,
    /// then a loose subsequence match so "pin" still finds "PINS".
    static func ranked(_ rules: [Rule], query: String) -> [Rule] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rules }

        func isSubsequence(of haystack: String) -> Bool {
            var index = needle.startIndex
            for character in haystack where character == needle[index] {
                index = needle.index(after: index)
                if index == needle.endIndex { return true }
            }
            return false
        }

        return rules.compactMap { rule -> (rule: Rule, score: Int)? in
            let code = rule.code.lowercased()
            let title = rule.title.lowercased()
            let section = rule.section.lowercased()
            let statement = rule.statement.lowercased()

            let score: Int
            if code == needle { score = 100 }
            else if code.hasPrefix(needle) { score = 90 }
            else if code.contains(needle) { score = 70 }
            else if title.lowercased().hasPrefix(needle) { score = 65 }
            else if title.contains(needle) { score = 55 }
            else if section.contains(needle) { score = 45 }
            else if statement.contains(needle) { score = 35 }
            else if isSubsequence(of: code) || isSubsequence(of: title) { score = 15 }
            else { return nil }

            return (rule, score)
        }
        .sorted { ($0.score, $1.rule.code) > ($1.score, $0.rule.code) }
        .map(\.rule)
    }
}
