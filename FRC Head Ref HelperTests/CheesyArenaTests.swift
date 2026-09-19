//
//  CheesyArenaTests.swift
//  FRC Head Ref HelperTests
//
//  The wire format, and the pipe end to end.
//
//  The JSON in here is shaped to Team254/cheesy-arena's real structs, which
//  carry no JSON tags — so the keys are Go field names, capitals and all. If
//  the arena ever renames a field these tests are what will catch it, so they
//  are written as literal payloads rather than built from the Swift types.
//
//  Most of this is pure decoding, because the mapping is where mistakes hide:
//  a match type off by one puts practice matches in the qualification
//  schedule, and Go's zero time read as a real date puts every unstarted match
//  in the year 1. The end-to-end tests then prove the same payloads survive an
//  actual websocket.
//

import Testing
import Foundation
@testable import FRC_Head_Ref_Helper

// The payload constants live in ArenaSocketTests.swift, beside the end-to-end
// tests that feed them through a real socket — same bytes, both layers.

// MARK: - Wire decoding

@Suite("Cheesy Arena wire format")
struct CheesyArenaWireTests {

    @Test("A match load decodes into this app's match")
    func matchLoadDecodes() throws {
        let frame = try JSONDecoder().decode(
            ArenaMatchLoadFrame.self, from: Data(matchLoadJSON.utf8)
        )
        let raw = frame.data.Match

        #expect(raw.level == .qualification)
        #expect(raw.TypeOrder == 41)
        #expect(raw.redTeams == ["8341", "254", "971"])
        #expect(raw.blueTeams == ["1678", "604", "100"])
        #expect(frame.data.IsReplay == false)
    }

    @Test("Match type maps to the right level, and Test is not a level")
    func matchTypeMapping() {
        // 0 Test, 1 Practice, 2 Qualification, 3 Playoff — from model/match.go.
        // Off-by-one here would file practice matches as quals.
        func level(_ type: Int) -> MatchLevel? {
            try? JSONDecoder().decode(ArenaMatch.self, from: Data("""
            {"Type":\(type),"TypeOrder":1,"Red1":1,"Red2":2,"Red3":3,\
            "Blue1":4,"Blue2":5,"Blue3":6}
            """.utf8)).level
        }
        #expect(level(0) == nil)            // Test is not part of the event
        #expect(level(1) == .practice)
        #expect(level(2) == .qualification)
        #expect(level(3) == .playoff)
    }

    @Test("Go's zero time reads as no time at all")
    func zeroTimeIsNil() throws {
        // Go marshals an unset time.Time as year one rather than null. Taken
        // literally it would make every unstarted match "behind schedule" by
        // about a million minutes.
        let frame = try JSONDecoder().decode(
            ArenaMatchLoadFrame.self, from: Data(matchLoadJSON.utf8)
        )
        #expect(frame.data.Match.actualStart == nil)
        #expect(frame.data.Match.scheduledStart != nil)
    }

    @Test("Scheduled start parses with and without fractional seconds")
    func timeParsing() {
        #expect(ArenaTime.parse("2026-09-19T10:30:00-07:00") != nil)
        #expect(ArenaTime.parse("2026-09-19T10:30:00.123Z") != nil)
        #expect(ArenaTime.parse("0001-01-01T00:00:00Z") == nil)
        #expect(ArenaTime.parse("") == nil)
        #expect(ArenaTime.parse(nil) == nil)
    }

    @Test("Match time decodes to an arena state")
    func matchTimeDecodes() throws {
        let frame = try JSONDecoder().decode(
            ArenaMatchTimeFrame.self, from: Data(matchTimeJSON.utf8)
        )
        #expect(frame.data.state == .autoPeriod)
        #expect(frame.data.MatchTimeSec == 8)
        #expect(frame.data.state?.isPlaying == true)
    }

    @Test("Empty alliance slots are dropped, not rendered as team 0")
    func emptySlots() throws {
        let raw = try JSONDecoder().decode(ArenaMatch.self, from: Data("""
        {"Type":2,"TypeOrder":1,"Red1":254,"Red2":0,"Red3":0,\
        "Blue1":1678,"Blue2":0,"Blue3":0}
        """.utf8))
        #expect(raw.redTeams == ["254"])
        #expect(raw.blueTeams == ["1678"])
    }

    @Test("The websocket URL is the documented unauthenticated endpoint")
    func endpoint() {
        let endpoints = ArenaEndpoints(host: "10.0.100.5")
        #expect(endpoints.websocket?.absoluteString == "ws://10.0.100.5:8080/api/arena/websocket")
        #expect(endpoints.matches(.qualification)?.absoluteString
                == "http://10.0.100.5:8080/api/matches/qualification")
    }
}

// MARK: - Merging into the model

// `.serialized` matters here. These are synchronous @MainActor tests that each
// build a whole Notebook, and Swift Testing runs suites in parallel — six of
// them contending with the other @MainActor suites (NotebookRulesTests,
// TeamAvatarStoreTests) wedged the main actor and took the test process down,
// which surfaced as unrelated suites "failing" in 0.000s.
@Suite("Arena feed into the notebook", .serialized)
@MainActor
struct NotebookArenaTests {

    private func match(_ level: MatchLevel, _ number: Int, play: Int = 1,
                       start: Date? = nil) -> Match {
        Match(key: MatchKey(level: level, number: number, play: play),
              red: ["254", "971", "8341"], blue: ["1678", "604", "100"],
              scheduledStart: start)
    }

    @Test("A loaded match becomes the current match")
    func matchLoadSetsCurrent() {
        let notebook = Notebook()
        notebook.apply(.matchLoaded(match(.qualification, 41)))
        #expect(notebook.currentMatchKey == MatchKey(level: .qualification, number: 41))
    }

    @Test("A replay is added alongside the original, not over it")
    func replayDoesNotOverwrite() {
        // The whole reason MatchKey carries a play: entries logged during the
        // first running of Q41 must stay attached to that play.
        let notebook = Notebook()
        notebook.schedule = []
        notebook.apply(.matchLoaded(match(.qualification, 41, play: 1)))
        notebook.apply(.matchLoaded(match(.qualification, 41, play: 2)))

        let q41 = notebook.schedule.filter { $0.key.number == 41 }
        #expect(q41.count == 2)
        #expect(notebook.currentMatchKey?.play == 2)
    }

    @Test("A timeout moves the coarse field state without anyone tapping")
    func timeoutPausesTheField() {
        let notebook = Notebook()
        notebook.apply(.matchTime(state: .timeoutActive, secondsIntoPeriod: 5))
        #expect(notebook.arenaState == .timeoutActive)
        #expect(notebook.fieldState == .paused)

        notebook.apply(.matchTime(state: .teleopPeriod, secondsIntoPeriod: 30))
        #expect(notebook.fieldState == .live)
    }

    @Test("Connection status reaches the model so the UI can be honest")
    func statusIsCarried() {
        let notebook = Notebook()
        #expect(!notebook.isArenaConnected)
        notebook.apply(.status(.connected(since: .now)))
        #expect(notebook.isArenaConnected)
        notebook.apply(.status(.waiting(retryAt: .now, attempt: 2, reason: "Closed")))
        #expect(!notebook.isArenaConnected)
    }

    @Test("Merging preserves queue data the arena knows nothing about")
    func mergePreservesQueueStatus() {
        // Queue status and late teams come from Nexus. A schedule refresh from
        // the arena must not wipe them.
        let notebook = Notebook()
        var queued = match(.qualification, 42)
        queued.missingTeams = ["604"]
        notebook.schedule = [queued]

        notebook.mergeArenaSchedule([match(.qualification, 42)])

        #expect(notebook.schedule.first?.missingTeams == ["604"])
    }

    @Test("A later load does not erase a start time already seen")
    func actualStartSurvives() {
        let notebook = Notebook()
        var started = match(.qualification, 43)
        started.actualStart = .now
        notebook.schedule = [started]

        notebook.mergeArenaSchedule([match(.qualification, 43)])

        #expect(notebook.schedule.first?.actualStart != nil)
    }
}
