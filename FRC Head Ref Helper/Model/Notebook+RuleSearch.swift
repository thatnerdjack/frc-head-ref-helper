//
//  Notebook+RuleSearch.swift
//  FRC Head Ref Helper
//
//  What the compose sheet's rule list shows, including the "hot rules" the
//  app learns from this event's own entries.
//

import Foundation

extension Notebook {

    // MARK: - Rule search

    /// What the compose sheet's rule list shows right now: search results if
    /// you have typed, your three most-used rules if you haven't, otherwise
    /// the head of the filtered list.
    var visibleRules: [Rule] {
        let pool = RuleCatalog.all.filter { ruleCategory.matches($0) }
        if !ruleQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(RuleCatalog.ranked(pool, query: ruleQuery).prefix(20))
        }
        if hotRulesFirst, !hotRules.isEmpty {
            // Learned from this event's own entries rather than a fixed list.
            let hot = hotRules.filter { ruleCategory.matches($0) }
            if !hot.isEmpty { return hot }
        }
        return Array(pool.prefix(20))
    }

    /// The rules actually used most at this event, most-used first. This is
    /// what "Learn my hot rules" means: after a few calls the list reorders
    /// itself around what this field is actually seeing.
    var hotRules: [Rule] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.ruleCode.isEmpty {
            counts[entry.ruleCode, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .compactMap { RuleCatalog.rule(for: $0.key) }
    }

    /// How often a rule has been cited at this event, for the "3x" counter.
    func useCount(for code: String) -> Int {
        entries.count { $0.ruleCode == code }
    }

    /// The counter above the rule list.
    var ruleCountLabel: String {
        let pool = RuleCatalog.all.filter { ruleCategory.matches($0) }
        if !ruleQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(visibleRules.count) of \(RuleCatalog.all.count) rules"
        }
        if hotRulesFirst, !hotRules.isEmpty { return "Most used here" }
        return "\(pool.count) rules"
    }

    var noRulesMessage: String? {
        guard visibleRules.isEmpty else { return nil }
        return "No rule matches “\(ruleQuery.trimmingCharacters(in: .whitespaces))”"
    }
}
