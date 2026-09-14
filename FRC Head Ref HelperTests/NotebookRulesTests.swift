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
    // the store is empty. Entries are stamped with the event the notebook will
    // open on, since reads are scoped by event — a test about badge precedence
    // should not also have to be a test about scoping.
    if let entries {
        for entry in entries {
            if entry.eventKey.isEmpty { entry.eventKey = SampleEvent.code.tbaKey }
            context.insert(entry)
        }
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

@Test("With Cheesy Arena running, frc.events is avatars only")
func arenaRestrictsFrcEventsToAvatars() {
    let config = SourceConfiguration()
    config.enabled = [.frcEvents, .cheesyArena]

    // Avatars are season-wide team data, so they cannot disagree with the
    // field. Everything else frc.events knows is about a different event.
    #expect(DataSourceKind.frcEvents.servedCapabilities(given: config.enabled) == [.teamAvatars])
    #expect(config.provider(for: .teamAvatars) == .frcEvents)
    #expect(config.provider(for: .matchSchedule) == .cheesyArena)

    // The easy-to-miss consequence, and the whole point of the Coverage
    // section: scores now have no source at all, and the app says so before
    // the event instead of guessing during it.
    #expect(config.provider(for: .officialScores) == nil)
    #expect(config.unmetCapabilities.contains(.officialScores))

    // TBA fills the scoring gap; frc.events stays restricted regardless.
    config.enabled.insert(.blueAlliance)
    #expect(config.provider(for: .officialScores) == .blueAlliance)
    #expect(config.provider(for: .teamAvatars) == .frcEvents)
}

@Test("A skipped source explains itself rather than vanishing")
func restrictionIsExplained() {
    let config = SourceConfiguration()

    // Nothing is being held back yet, so nothing needs explaining.
    config.enabled = [.frcEvents, .blueAlliance]
    #expect(DataSourceKind.frcEvents.restrictionNote(given: config.enabled) == nil)
    #expect(config.restrictionNote(for: .officialScores) == nil)

    config.enabled.insert(.cheesyArena)
    #expect(DataSourceKind.frcEvents.restrictionNote(given: config.enabled) != nil)
    // The row where frc.events was passed over carries the reason…
    #expect(config.restrictionNote(for: .officialScores) != nil)
    // …but one it still wins does not.
    #expect(config.restrictionNote(for: .teamAvatars) == nil)
    // Nor does a capability frc.events was never ranked for in the first place.
    #expect(config.restrictionNote(for: .queueStatus) == nil)

    // The ranking itself is a constant and must not move with the toggles.
    #expect(DataSourceKind.preferenceOrder(for: .matchSchedule)
            == [.cheesyArena, .frcEvents, .blueAlliance])
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

@MainActor
@Test("A duplicated replay notification does not create two plays")
func replayIsIdempotent() throws {
    // Duplicate websocket frames are normal, and the original play stays in
    // the schedule by design because it keeps its entries. So a naive "find
    // the key, insert play + 1" fires twice and produces two matches that are
    // both Q41.2 — including two rows with the same Identifiable id.
    let notebook = try makeNotebook(with: [])
    let original = try #require(notebook.currentMatch)

    notebook.recordReplay(of: original.key)
    notebook.recordReplay(of: original.key)

    let plays = notebook.schedule.filter {
        $0.key.level == original.key.level && $0.key.number == original.key.number
    }
    #expect(plays.count == 2)
    #expect(Set(plays.map(\.id)).count == 2)
    #expect(notebook.currentMatch?.key.play == 2)
}

// MARK: - Event scoping

@MainActor
@Test("A team's record is this event's record, not every event's")
func entriesAreScopedToTheirEvent() throws {
    // The bug this pins: before entries carried an event key, a card picked up
    // at last week's offseason counted against a team today, and the
    // escalation hint said "at this event" while counting across all of them.
    let here = SampleEvent.code.tbaKey
    let elsewhere = "2026casd"

    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410", eventKey: here),
        RefEntry(subject: "1234", severity: .redCard, ruleCode: "G206", eventKey: elsewhere),
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410", eventKey: elsewhere),
    ])

    // The red card belongs to another event and must not outrank today's
    // single warning.
    #expect(notebook.badge(for: "1234").text == "1 WARNING")
    #expect(notebook.counts(for: "1234").total == 1)
    // Two G410 warnings exist in the store, but only one at this event.
    #expect(notebook.escalationHint(for: "1234") == nil)
    #expect(notebook.entriesToday == 1)
    #expect(notebook.cardsIssued == 0)
}

@MainActor
@Test("Switching events swaps the notebook without destroying either one")
func switchingEventsKeepsBothNotebooks() throws {
    let here = SampleEvent.code.tbaKey
    let elsewhere = "2026casd"

    let notebook = try makeNotebook(with: [
        RefEntry(subject: "1234", severity: .verbalWarning, ruleCode: "G410", eventKey: here),
        RefEntry(subject: "7777", severity: .yellowCard, ruleCode: "G206", eventKey: elsewhere),
    ])
    #expect(notebook.entriesToday == 1)
    #expect(notebook.badge(for: "7777").isEmpty)

    notebook.eventCodeDraft = elsewhere
    notebook.applyEventCode()

    // The other event's notebook is now loaded...
    #expect(notebook.eventCode.tbaKey == elsewhere)
    #expect(notebook.entriesToday == 1)
    #expect(notebook.badge(for: "7777").text == "YELLOW")
    #expect(notebook.badge(for: "1234").isEmpty)

    // ...and switching back finds the first one intact. Nothing was deleted.
    notebook.eventCodeDraft = here
    notebook.applyEventCode()
    #expect(notebook.badge(for: "1234").text == "1 WARNING")
    #expect(notebook.badge(for: "7777").isEmpty)
}

@MainActor
@Test("An entry is stamped with the event it was written at")
func savedEntryCarriesTheCurrentEvent() throws {
    let notebook = try makeNotebook(with: [])
    notebook.selectedSubject = "8341"
    notebook.selectedRuleCode = "G418"
    notebook.save()

    let saved = try #require(notebook.entries.first)
    #expect(saved.eventKey == notebook.eventCode.tbaKey)
}

// MARK: - Clocks

@MainActor
@Test("The timeout clock is absent when none is running, not zero")
func timeoutClockIsAbsentWhenNotRunning() throws {
    let notebook = try makeNotebook(with: [])
    // The old model counted down from 204 forever and wrapped, so a referee
    // glancing at the phone saw a live timeout that did not exist.
    #expect(notebook.timeoutEndsAt == nil)
    #expect(notebook.breakSecondsRemaining == 0)
}

#if os(iOS)
@MainActor
@Test("The Live Activity countdown is anchored to the match, not to the tick")
func countdownEndDoesNotDriftWithTheClock() throws {
    // `now + remaining` drifts by the truncated fractional second every tick,
    // so the ContentState hash changed once a second and the controller's
    // signature check never matched — an ActivityKit push every second, which
    // is exactly what carrying the countdown as an end date exists to avoid.
    let notebook = try makeNotebook(with: [])
    let match = try #require(notebook.currentMatch)
    let started = try #require(match.actualStart)
    #expect(notebook.isMatchRunning)

    let state = notebook.liveActivityState
    #expect(state.countdownEnd == started.addingTimeInterval(Notebook.matchLength))
    #expect(notebook.liveActivityState.hashValue == state.hashValue)
}
#endif

@MainActor
@Test("Entries written before scoping existed are adopted, not orphaned")
func unfiledEntriesAreAdoptedOnUpgrade() throws {
    // Reads are scoped by event, so a row left at the default empty key is
    // invisible. Upgrading from a build without event keys must not present a
    // referee with a blank notebook.
    let container = try ModelContainer(
        for: RefEntry.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    // Deliberately NOT stamped — this is what the old schema wrote.
    context.insert(RefEntry(subject: "8341", severity: .verbalWarning, ruleCode: "G418"))
    context.insert(RefEntry(subject: "8341", severity: .verbalWarning, ruleCode: "G418"))
    try context.save()

    let notebook = Notebook()
    notebook.attach(to: context)

    #expect(notebook.entries.count == 2)
    #expect(notebook.entries.allSatisfy { $0.eventKey == notebook.eventCode.tbaKey })
    #expect(notebook.badge(for: "8341").text == "2 WARNINGS")
}
