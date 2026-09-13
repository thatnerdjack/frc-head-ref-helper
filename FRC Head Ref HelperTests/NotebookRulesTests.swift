//
//  NotebookRulesTests.swift
//  FRC Head Ref HelperTests
//
//  Tests for the judgement calls the app makes on a referee's behalf. These
//  are the parts worth defending out loud: how a team's record collapses into
//  one badge, when the app decides to warn about escalation, and how rule
//  search ranks 53 rules.
//

import Testing
import Foundation
import SwiftData
@testable import FRC_Head_Ref_Helper

@MainActor
private func makeNotebook(with entries: [RefEntry]? = nil) throws -> Notebook {
    let container = try ModelContainer(
        for: RefEntry.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    // Passing entries explicitly skips the sample seed, which only fires when
    // the store is empty.
    if let entries {
        for entry in entries { context.insert(entry) }
        try context.save()
    }
    let notebook = Notebook()
    notebook.attach(to: context)
    return notebook
}

// MARK: - Badge precedence

@MainActor
@Test("A red card outranks everything else a team has picked up")
func redCardWinsPrecedence() throws {
    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
        RefEntry(subject: "1234", severity: .yellowCard, ruleCode: "G206"),
        RefEntry(subject: "1234", severity: .redCard, ruleCode: "H602"),
    ])
    #expect(notebook.badge(for: "1234").text == "RED CARD")
}

@MainActor
@Test("Warnings are counted and pluralised, not just flagged")
func warningsArePluralised() throws {
    let one = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
    ])
    #expect(one.badge(for: "1234").text == "1 WARNING")

    let two = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G424"),
    ])
    #expect(two.badge(for: "1234").text == "2 WARNINGS")
}

@MainActor
@Test("A team with nothing against it carries no badge")
func cleanTeamHasNoBadge() throws {
    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
    ])
    #expect(notebook.badge(for: "9999").isEmpty)
}

// MARK: - Escalation

@MainActor
@Test("Two warnings for the SAME rule raises the escalation hint")
func repeatOfSameRuleEscalates() throws {
    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
    ])
    let hint = try #require(notebook.escalationHint(for: "1234"))
    #expect(hint.contains("G410"))
    #expect(hint.contains("2 verbal warnings"))
}

@MainActor
@Test("Warnings for DIFFERENT rules do not escalate")
func differentRulesDoNotEscalate() throws {
    // This is the distinction that matters on the field: the manual escalates
    // on a repeat of the same violation, not on a team being generally sloppy.
    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G424"),
    ])
    #expect(notebook.escalationHint(for: "1234") == nil)
}

@MainActor
@Test("Turning escalation hints off silences them")
func hintsCanBeDisabled() throws {
    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410"),
    ])
    notebook.escalationHintsEnabled = false
    #expect(notebook.escalationHint(for: "1234") == nil)
}

// MARK: - Rule search

@Test("An exact rule code ranks first")
func exactCodeRanksFirst() {
    let results = RuleCatalog.ranked(RuleCatalog.all, query: "G410")
    #expect(results.first?.code == "G410")
}

@Test("Searching by plain language finds the rule")
func titleSearchWorks() {
    // Pinning is G418 in the 2026 manual ("There's a 3-count on PINS").
    let results = RuleCatalog.ranked(RuleCatalog.all, query: "pins")
    #expect(results.contains { $0.code == "G418" })
}

@Test("A partial code floats that series to the top")
func partialCodeMatchesSeries() {
    // Ranking, not filtering: loose subsequence matches still appear far down
    // the list, so the guarantee is about what comes FIRST.
    let results = RuleCatalog.ranked(RuleCatalog.all, query: "g41")
    #expect(results.count >= 5)
    #expect(results.prefix(5).allSatisfy { $0.code.hasPrefix("G41") })
}

// MARK: - The real manual

@Test("The 2026 manual loaded, with the series it actually has")
func manualLoaded() {
    #expect(RuleCatalog.all.count > 200)
    #expect(RuleCatalog.teamUpdate == 22)
    let series = Set(RuleCatalog.all.map(\.category))
    // 2026 has G/R/I/T/E/C and, notably, no H series.
    #expect(series.contains("G"))
    #expect(series.contains("R"))
    #expect(!series.contains("H"))
}

@Test("A rule's severity suggestion follows what the manual says")
func severitySuggestionFollowsManual() throws {
    // G101 carries "VERBAL WARNING. YELLOW CARD if subsequent violations",
    // so the first-offence outcome is what should be suggested.
    let g101 = try #require(RuleCatalog.rule(for: "G101"))
    #expect(g101.suggestedSeverity == .verbalWarning)
}

// MARK: - Event codes

@Test("Both spellings of an event code parse to the same event")
func eventCodeAcceptsBothSpellings() throws {
    let tba = try #require(EventCode("2026cada"))
    #expect(tba.season == 2026)
    #expect(tba.tbaKey == "2026cada")
    #expect(tba.frcEventsCode == "CADA")

    // Upper case, and a bare code with an assumed season.
    #expect(EventCode("2026CADA")?.tbaKey == "2026cada")
    #expect(EventCode("cada", defaultSeason: 2026)?.tbaKey == "2026cada")
}

@Test("Nonsense is rejected rather than guessed at")
func eventCodeRejectsJunk() {
    #expect(EventCode("") == nil)
    #expect(EventCode("!!!") == nil)
}

// MARK: - Replays

@Test("A replayed match is a distinct play, not the same one")
func replayIsADistinctPlay() {
    let first = MatchKey(level: .qualification, number: 41)
    let replay = MatchKey(level: .qualification, number: 41, play: 2)

    #expect(first != replay)
    #expect(first.storageKey == "Q41.1")
    #expect(replay.storageKey == "Q41.2")
    // Both read as Q41 where space is tight, but the replay says so in full.
    #expect(first.short == replay.short)
    #expect(replay.display.contains("replay"))
}

// MARK: - Data sources

@Test("Capabilities resolve to the best enabled source, not one chosen source")
func capabilitiesResolveAcrossSources() {
    let config = SourceConfiguration()
    config.enabled = [.frcEvents]
    // frc.events has no idea what is queued.
    #expect(config.provider(for: .queueStatus) == nil)
    #expect(config.provider(for: .officialScores) == .frcEvents)

    // Adding Nexus fills the queueing gap without displacing anything else.
    config.enabled.insert(.frcNexus)
    #expect(config.provider(for: .queueStatus) == .frcNexus)
    #expect(config.provider(for: .officialScores) == .frcEvents)

    // At an offseason the field server is the authority on live state and on
    // team names, because it is the only thing that knows about B-teams.
    config.enabled.insert(.cheesyArena)
    #expect(config.provider(for: .liveMatchState) == .cheesyArena)
    #expect(config.provider(for: .teamNames) == .cheesyArena)
}

@Test("Unmet capabilities are reported so gaps are visible before the event")
func unmetCapabilitiesAreReported() {
    let config = SourceConfiguration()
    config.enabled = []
    #expect(config.unmetCapabilities.count == SourceCapability.allCases.count)

    config.enabled = Set(DataSourceKind.allCases)
    #expect(config.unmetCapabilities.isEmpty)
}

@Test("Arena match states map to the Go enum's ordering")
func arenaStatesMatchCheesyArena() {
    // Order mirrors MatchState in cheesy-arena field/arena.go.
    #expect(ArenaMatchState(rawValue: 0) == .preMatch)
    #expect(ArenaMatchState(rawValue: 2) == .autoPeriod)
    #expect(ArenaMatchState(rawValue: 4) == .teleopPeriod)
    #expect(ArenaMatchState(rawValue: 6) == .timeoutActive)
    #expect(ArenaMatchState.teleopPeriod.isPlaying)
    #expect(!ArenaMatchState.postMatch.isPlaying)
}

@Test("Nonsense matches nothing rather than everything")
func nonsenseMatchesNothing() {
    #expect(RuleCatalog.ranked(RuleCatalog.all, query: "zzzqqq").isEmpty)
}

@Test("Every rule has a usable short name for entry rows")
func everyRuleHasShortName() {
    for rule in RuleCatalog.all {
        #expect(!RuleCatalog.shortName(for: rule.code).isEmpty)
    }
}

// MARK: - Export

@MainActor
@Test("CSV escapes quotes so notes survive the round trip")
func csvEscapesQuotes() throws {
    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .teamNote, ruleCode: "R201",
                 note: "Driver said \"it's fine\", it was not"),
    ])
    let csv = notebook.exportCSV
    #expect(csv.contains("\"\"it's fine\"\""))
    // One header line plus one entry — the embedded comma must not split the row.
    #expect(csv.split(separator: "\n").count == 2)
}


// MARK: - Event phase

@MainActor
@Test("Stage is read off the field, not set by hand")
func phaseFollowsTheMatchOnTheField() throws {
    let notebook = try makeNotebook(with: [])

    // The sample schedule is qualifications.
    #expect(notebook.phase == .qualification)
    #expect(!notebook.canLogAgainstAlliance)

    // Put a playoff match on the field and the stage follows.
    let playoff = MatchKey(level: .playoff, number: 1)
    notebook.schedule = [Match(key: playoff,
                               red: ["8341", "5883", "6440"],
                               blue: ["7460", "3129", "5510"],
                               scheduledStart: .now,
                               actualStart: .now,
                               queueStatus: .onField)]
    notebook.currentMatchKey = playoff
    #expect(notebook.phase == .playoff)
    #expect(notebook.canLogAgainstAlliance)
}

@MainActor
@Test("Starting a compose during quals never targets an alliance")
func composeDuringQualsTargetsTeam() throws {
    let notebook = try makeNotebook(with: [])
    #expect(notebook.phase == .qualification)
    notebook.selectedSubject = "Alliance 4"
    notebook.startCompose()
    #expect(notebook.composeTarget == .team)
}

// MARK: - Out-of-order and replayed matches

@MainActor
@Test("Play order follows what actually happened, not the schedule")
func playOrderFollowsActualStarts() throws {
    let notebook = try makeNotebook(with: [])
    let order = notebook.matchesInPlayOrder

    // Matches that have run come first, in the order they ran.
    let played = order.filter { $0.actualStart != nil }
    let starts = played.compactMap(\.actualStart)
    #expect(starts == starts.sorted())
    // Everything already played precedes everything still to come.
    let firstUnplayed = order.firstIndex { $0.actualStart == nil } ?? order.count
    #expect(order.prefix(firstUnplayed).allSatisfy { $0.actualStart != nil })
}

@MainActor
@Test("Replaying a match keeps the original play's entries intact")
func replayPreservesOriginalPlay() throws {
    let notebook = try makeNotebook(with: [])
    let original = try #require(notebook.currentMatch)

    // An entry logged during the first play.
    notebook.selectedSubject = original.onField[0]
    notebook.selectedRuleCode = "G418"
    notebook.save()
    let logged = try #require(notebook.entries.first)
    #expect(logged.matchKeyRaw == original.key.storageKey)

    notebook.recordReplay(of: original.key)

    let replay = try #require(notebook.currentMatch)
    #expect(replay.key.number == original.key.number)
    #expect(replay.key.play == original.key.play + 1)
    #expect(replay.key != original.key)

    // The entry still points at the play it happened in, not the replay.
    #expect(logged.matchKeyRaw == original.key.storageKey)
    #expect(notebook.schedule.contains { $0.key == original.key })
}
