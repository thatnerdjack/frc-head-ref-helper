//
//  Notebook.swift
//  FRC Head Ref Helper
//
//  The app's state and all of its derived reading: which screen is up, what
//  the compose sheet currently holds, and — the part that matters — how a
//  pile of entries turns into the badges, escalation hints and reports the
//  design shows.
//
//  The rules encoded here are the ones a head ref actually has to hold in
//  their head, so they live in one testable place instead of inside views:
//
//    • A team shows ONE badge, by precedence: red card > yellow > warnings > note.
//    • Two verbal warnings for the SAME rule is the escalation trigger.
//    • Alliance entries attach to "Alliance 4", not to its three teams.
//

import Foundation
import SwiftData
import SwiftUI

@Observable
final class Notebook {

    // MARK: - Navigation

    /// The three tabs. Selection is driven by a system `TabView`, which brings
    /// the Liquid Glass tab bar with it.
    enum MainTab: Hashable {
        case now, teams, settings
    }

    /// Pushed destinations inside the Settings tab.
    enum SettingsRoute: Hashable {
        case eventPicker, arena
    }

    /// Who a new entry is being written against.
    enum ComposeTarget: String, CaseIterable, Identifiable {
        case team, alliance
        var id: String { rawValue }
        var label: String { self == .team ? "Team" : "Alliance" }
    }

    /// Whether the field is running. A break covers a lunch break, a playoff
    /// timeout and a field fault — the design uses one box for all three.
    /// `dayComplete` is the third state the design draws (artboard 2d) but
    /// never gives a route to, because in a finished app the schedule would
    /// put you there. Until match data is wired up, the Now header's status
    /// pill cycles through all three, so the state is reachable and testable
    /// rather than dead code.
    enum FieldState: CaseIterable {
        case live, paused, dayComplete

        var label: String {
            switch self {
            case .live: "LIVE"
            case .paused: "PAUSED"
            case .dayComplete: "DAY DONE"
            }
        }
    }

    // MARK: - State

    var selectedTab: MainTab = .now
    var fieldState: FieldState = .live

    // Navigation paths, one per tab, so each tab keeps its own history the way
    // a system NavigationStack expects.
    var nowPath: [String] = []
    var teamsPath: [String] = []
    var settingsPath: [SettingsRoute] = []

    /// The team or alliance whose page is open, and the default subject when
    /// the compose sheet is raised.
    var selectedSubject: String?

    var isComposing = false
    var toast: String?

    // Compose sheet
    var composeTarget: ComposeTarget = .team
    var selectedAllianceSeed = 4
    var selectedRuleCode = RuleCatalog.defaultRuleCode {
        didSet {
            // The manual already says what a violation carries, so preselect
            // it. Always overridable — the head ref's judgement wins.
            if let suggested = RuleCatalog.rule(for: selectedRuleCode)?.suggestedSeverity {
                selectedSeverity = suggested
            }
        }
    }
    var selectedSeverity: Severity = .verbalWarning
    var noteText = ""
    var ruleQuery = ""
    var ruleCategory: RuleCategory = .all

    // Search fields
    var teamQuery = ""
    var eventQuery = ""

    // Settings
    /// Sources are independently enabled; several run at once.
    var sources = SourceConfiguration()
    /// Head referees are not handed an event through any system we can read,
    /// so the code is typed in. Either spelling is accepted.
    var eventCode = SampleEvent.code
    var eventCodeDraft = SampleEvent.code.tbaKey
    var showExportPreview = false
    var escalationHintsEnabled = true
    var hotRulesFirst = true
    var watchEnabled = true {
        didSet {
            if watchEnabled { syncLiveActivity() } else { stopLiveActivity() }
        }
    }


    /// What Cheesy Arena last told us the field is doing. Nil when no live
    /// source is connected, in which case the schedule drives the UI instead.
    var arenaState: ArenaMatchState?

    /// The schedule in SCHEDULE order, and the key of the match on the field.
    var schedule: [Match] = SampleEvent.schedule()
    var currentMatchKey: MatchKey? = MatchKey(level: .qualification, number: 41)

    /// Ticks once a second to drive the clocks.
    private(set) var now: Date = .now

    // A standard FRC match: 15s autonomous plus 135s teleop. Used for the
    // watch's "time left" readout, which is explicitly an estimate derived
    // from the start time rather than a feed from FMS.
    static let matchLength: TimeInterval = 150
    var breakSecondsRemaining = 204

    /// Loaded entries, newest first. Held here rather than `@Query`'d per view
    /// so badges and hints can be computed in one place.
    private(set) var entries: [RefEntry] = []

    private var context: ModelContext?
    private var ticker: Task<Void, Never>?
    private var toastDismissal: Task<Void, Never>?

    // The sample event's progress, quoted in the export header.
    let qualsPlayed = 41
    let qualsTotal = 78
    let eventName = "Capital District"

    // MARK: - Lifecycle

    func attach(to context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        seedIfNeeded()
        reload()
        startClock()
        #if DEBUG
        applyDebugLaunchArguments()
        #endif
    }

    #if DEBUG
    /// Development helper. Opens a screen straight from the command line:
    ///
    ///     xcrun simctl launch <device> me.jackdoherty.FRC-Head-Ref-Helper \
    ///         -refScreen settings
    ///
    /// Valid values: now, teams, team, settings, event, arena, compose, break,
    /// day. Used for grabbing screenshots of a specific screen without tapping
    /// through the app. Compiled out of release builds.
    private func applyDebugLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-refScreen"),
              arguments.index(after: flag) < arguments.endIndex else { return }

        switch arguments[arguments.index(after: flag)] {
        case "teams": selectedTab = .teams
        case "team": selectedTab = .teams; teamsPath = ["8341"]
        case "settings": selectedTab = .settings
        case "event": selectedTab = .settings; settingsPath = [.eventPicker]
        case "arena": selectedTab = .settings; settingsPath = [.arena]
        case "compose": selectedSubject = "8341"; isComposing = true
        case "break": fieldState = .paused
        case "day": fieldState = .dayComplete
        default: selectedTab = .now
        }
    }
    #endif

    private func startClock() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.now = .now
                self.breakSecondsRemaining = self.breakSecondsRemaining > 0 ? self.breakSecondsRemaining - 1 : 204
                self.syncLiveActivity()
            }
        }
    }

    deinit {
        ticker?.cancel()
        toastDismissal?.cancel()
    }

    private func seedIfNeeded() {
        guard let context else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<RefEntry>())) ?? 0
        guard existing == 0 else { return }
        for entry in RefEntry.sampleEntries() { context.insert(entry) }
        try? context.save()
    }

    private func reload() {
        guard let context else { return }
        let descriptor = FetchDescriptor<RefEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        entries = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Reading a team's record

    struct Counts {
        var warnings = 0
        var yellow = 0
        var red = 0
        var notes = 0
        var total = 0
    }

    func counts(for subject: String) -> Counts {
        var counts = Counts()
        for entry in entries where entry.subject == subject {
            counts.total += 1
            switch entry.severity {
            case .verbalWarning: counts.warnings += 1
            case .yellowCard: counts.yellow += 1
            case .redCard, .disableDQ: counts.red += 1
            case .teamNote, .inspectionConcern: counts.notes += 1
            case .foulTally: break
            }
        }
        return counts
    }

    /// The single badge shown for a team. Precedence, not accumulation: a team
    /// carrying a red card reads "RED CARD", never "RED CARD + 2 WARNINGS".
    func badge(for subject: String) -> TeamBadge {
        let counts = counts(for: subject)
        if counts.red > 0 {
            return TeamBadge(text: "RED CARD", background: Color(hex: 0xD64040), foreground: .white)
        }
        if counts.yellow > 0 {
            return TeamBadge(text: "YELLOW", background: Color(hex: 0xE0B93A), foreground: Color(hex: 0x17140A))
        }
        if counts.warnings > 0 {
            let text = "\(counts.warnings) \(counts.warnings > 1 ? "WARNINGS" : "WARNING")"
            return TeamBadge(text: text, background: RefColor.gold, foreground: Color(hex: 0x17140A))
        }
        if counts.notes > 0 {
            return TeamBadge(text: "NOTE", background: Color.white.opacity(0.18), foreground: .white)
        }
        return .none
    }

    /// The compact badge the watch shows, where there is no room to spell it
    /// out: "R", "Y", "2W", "N".
    func shortBadge(for subject: String) -> String {
        let counts = counts(for: subject)
        if counts.red > 0 { return "R" }
        if counts.yellow > 0 { return "Y" }
        if counts.warnings > 0 { return "\(counts.warnings)W" }
        if counts.notes > 0 { return "N" }
        return ""
    }

    /// The escalation hint. Two verbal warnings for the *same rule* is the
    /// point the manual starts pointing at a yellow card, so that — and only
    /// that — is what raises a hint. Different rules don't stack.
    func escalationHint(for subject: String, in list: [RefEntry]? = nil) -> String? {
        guard escalationHintsEnabled else { return nil }
        let source = list ?? entries
        var byRule: [String: Int] = [:]
        for entry in source where entry.subject == subject && entry.severity == .verbalWarning {
            byRule[entry.ruleCode, default: 0] += 1
        }
        guard let (code, count) = byRule.first(where: { $0.value >= 2 }) else { return nil }
        return "\(subject) has \(count) verbal warnings for \(code) at this event. "
             + "A repeat is where the manual points at a yellow."
    }

    func entries(for subject: String) -> [RefEntry] {
        // Foul tallies are data-only since turn 2 of the design dropped them
        // from the UI; they stay out of the team page.
        entries.filter { $0.subject == subject && $0.severity != .foulTally }
    }

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

    // MARK: - Clock labels

    /// mm:ss for a second count, clamped at zero.
    func clockText(_ seconds: Int) -> String { clock(seconds) }

    private func clock(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 60):\(String(format: "%02d", clamped % 60))"
    }

    var breakClock: String { clock(breakSecondsRemaining) }

    /// Seconds until the next match is scheduled to start.
    var secondsToNextMatch: Int {
        guard let start = nextMatch?.scheduledStart else { return 0 }
        return Int(start.timeIntervalSince(now))
    }

    var nextMatchClock: String { clock(secondsToNextMatch) }

    /// An UNOFFICIAL estimate of time left in the match on the field, derived
    /// from when it actually started. FMS is the only authority on match time;
    /// this is close enough to answer "how long have I got", which is all the
    /// watch is being asked.
    var matchSecondsRemaining: Int? {
        guard let match = currentMatch, let started = match.actualStart else { return nil }
        let remaining = Self.matchLength - now.timeIntervalSince(started)
        guard remaining > -30 else { return nil }   // stale: match long over
        return Int(max(0, remaining))
    }

    var isMatchRunning: Bool {
        if let arenaState { return arenaState.isPlaying }
        return matchSecondsRemaining.map { $0 > 0 } ?? false
    }

    /// The single clock the watch shows: time left in the match if one is
    /// running, otherwise the countdown to whatever happens next.
    var primaryClock: (label: String, value: String) {
        if fieldState == .paused || arenaState?.isTimeout == true {
            return ("TIMEOUT", breakClock)
        }
        if isMatchRunning, let remaining = matchSecondsRemaining {
            return (arenaState?.label.uppercased() ?? "MATCH", clock(remaining))
        }
        return ("NEXT MATCH", nextMatchClock)
    }

    /// "NEXT IN 4:12" while play is running, "AFTER THE BREAK" when paused.
    var nextMatchLeadLabel: String {
        fieldState == .paused ? "AFTER THE BREAK" : "NEXT IN \(nextMatchClock)"
    }

    // MARK: - Schedule

    /// Read off the field rather than set in Settings: whatever match is on
    /// now (or up next) says which stage the event is in.
    var phase: EventPhase {
        EventPhase(matchLevel: (currentMatch ?? nextMatch)?.key.level)
    }

    var currentMatch: Match? {
        guard let currentMatchKey else { return nil }
        return schedule.first { $0.key == currentMatchKey }
    }

    /// The next match to be played. Explicitly NOT "the one after the current
    /// index": matches run out of order often enough that the next one is
    /// whichever unplayed match is scheduled soonest.
    var nextMatch: Match? {
        schedule
            .filter { $0.queueStatus != .played && $0.key != currentMatchKey }
            .min { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }
    }

    /// The schedule ordered by what actually happened: matches that have run,
    /// in the order they ran, then everything still to come by schedule.
    var matchesInPlayOrder: [Match] {
        let played = schedule.filter { $0.actualStart != nil }
            .sorted { ($0.actualStart ?? .distantPast) < ($1.actualStart ?? .distantPast) }
        let upcoming = schedule.filter { $0.actualStart == nil }
            .sorted { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }
        return played + upcoming
    }

    /// How far behind the schedule the event is running, from the most recent
    /// match that has both a scheduled and an actual start.
    var minutesBehindSchedule: Int? {
        matchesInPlayOrder.reversed().first { $0.minutesBehindSchedule != nil }?.minutesBehindSchedule
    }

    /// Records that the field is replaying a match after an ARENA FAULT.
    ///
    /// This is an INGEST operation, not a user action: FMS decides when a
    /// replay happens, it can happen to any match, and it can happen at any
    /// time. The schedule source calls this; there is deliberately no button
    /// for it. The original play keeps its entries, and the replay becomes a
    /// new play of the same match number.
    func recordReplay(of key: MatchKey) {
        guard let index = schedule.firstIndex(where: { $0.key == key }) else { return }
        let match = schedule[index]

        var original = match
        original.queueStatus = .played
        schedule[index] = original

        var replay = Match(key: MatchKey(level: match.key.level,
                                         number: match.key.number,
                                         play: match.key.play + 1),
                           red: match.red, blue: match.blue,
                           scheduledStart: now,
                           actualStart: nil,
                           queueStatus: .onDeck)
        replay.missingTeams = []
        schedule.insert(replay, at: index + 1)
        currentMatchKey = replay.key
        show(toast: "\(match.key.short) is being replayed. Entries from the earlier play are kept.")
    }

    // MARK: - Actions

    func startCompose() {
        selectedSubject = activeSubject
        composeTarget = (canLogAgainstAlliance && isAllianceSubject) ? .alliance : .team
        isComposing = true
    }

    /// Alliance-wide entries are a playoff concept. Before alliance selection
    /// there is nothing to attach one to, so the WHO picker is not offered.
    var canLogAgainstAlliance: Bool { phase.alliancesExist }

    func cancelCompose() { isComposing = false }

    /// Accepts whatever the head ref typed, in either spelling.
    func applyEventCode() {
        guard let parsed = EventCode(eventCodeDraft) else { return }
        eventCode = parsed
        eventCodeDraft = parsed.tbaKey
        show(toast: "Loaded \(parsed.tbaKey). Pulling from \(enabledSourceSummary).")
    }

    private var enabledSourceSummary: String {
        let names = DataSourceKind.allCases.filter { sources.isEnabled($0) }.map(\.name)
        return names.isEmpty ? "no sources" : names.formatted(.list(type: .and))
    }

    /// Advances live -> paused -> day complete -> live.
    func advanceFieldState() {
        let all = FieldState.allCases
        let next = ((all.firstIndex(of: fieldState) ?? -1) + 1) % all.count
        fieldState = all[next]
    }

    var saveButtonTitle: String {
        composeTarget == .alliance ? "Save · Alliance \(selectedAllianceSeed)" : "Save · \(activeSubject)"
    }

    /// Commits the entry, lands you on the subject's page, and raises either
    /// the escalation hint or a plain confirmation. The hint wins: if this
    /// entry just became the second warning for a rule, that is the thing you
    /// need to see, not "Logged".
    func save() {
        guard let context else { return }
        let subject = composeTarget == .alliance
            ? "Alliance \(selectedAllianceSeed)"
            : activeSubject

        let entry = RefEntry(
            subject: subject,
            severity: selectedSeverity,
            ruleCode: selectedRuleCode,
            matchKeyRaw: currentMatch?.key.storageKey ?? "",
            matchLabel: currentMatch?.key.display ?? "—",
            timeLabel: Self.timeFormatter.string(from: .now),
            note: noteText
        )
        context.insert(entry)
        try? context.save()
        reload()

        noteText = ""
        isComposing = false
        selectedSubject = subject

        show(toast: escalationHint(for: subject)
             ?? "Logged · \(subject) · \(selectedSeverity.label)")
    }

    private func show(toast message: String) {
        toast = message
        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: - Live Activity

    #if canImport(ActivityKit) && os(iOS)
    /// The Live Activity's view of the world. Built from the same values the
    /// Now screen and the watch use, so the three never disagree.
    var liveActivityState: MatchActivityAttributes.ContentState {
        let showingCurrent = isMatchRunning && currentMatch != nil
        let match = showingCurrent ? currentMatch : (nextMatch ?? currentMatch)

        func chips(_ teams: [String], isRed: Bool) -> [TeamChip] {
            teams.map { TeamChip(number: $0, badge: shortBadge(for: $0), isRed: isRed) }
        }

        return MatchActivityAttributes.ContentState(
            matchLabel: match?.key.display ?? "—",
            stateLabel: primaryClock.label,
            countdownEnd: countdownEnd,
            isMatchRunning: showingCurrent,
            red: chips(match?.red ?? [], isRed: true),
            blue: chips(match?.blue ?? [], isRed: false),
            missingTeams: showingCurrent ? [] : (match?.missingTeams ?? []),
            queueLabel: showingCurrent ? nil : match?.queueStatus.label
        )
    }

    /// When the clock currently being shown reaches zero.
    private var countdownEnd: Date? {
        if fieldState == .paused || arenaState?.isTimeout == true {
            return now.addingTimeInterval(TimeInterval(breakSecondsRemaining))
        }
        if isMatchRunning, let remaining = matchSecondsRemaining {
            return now.addingTimeInterval(TimeInterval(remaining))
        }
        return nextMatch?.scheduledStart
    }

    private func syncLiveActivity() {
        LiveActivityController.shared.sync(eventName: eventName,
                                           state: liveActivityState,
                                           enabled: watchEnabled)
    }

    /// Called when the user turns the feature off, or the event ends.
    func stopLiveActivity() { LiveActivityController.shared.end() }
    #else
    private func syncLiveActivity() {}
    func stopLiveActivity() {}
    #endif

    // MARK: - Export

    var exportSummary: String {
        let subjects = Set(entries.map(\.subject)).count
        return "\(entries.count) entries across \(subjects) teams. Markdown for email, CSV for the archive."
    }

    /// The report a head ref emails at the end of the day. Grouped the way the
    /// design's preview shows it: cards first, then warnings, then notes.
    var exportMarkdown: String {
        var lines = [
            "# \(eventName) — head referee log",
            "\(eventCode.tbaKey) · \(qualsPlayed) of \(qualsTotal) quals played · exported \(Self.timeFormatter.string(from: .now))",
            "",
            "## Cards",
        ]

        let cards = entries.filter { [.yellowCard, .redCard, .disableDQ].contains($0.severity) }
        lines += cards.isEmpty
            ? ["- none"]
            : cards.map { "- \($0.subject) — \($0.severity.short.lowercased()), \($0.matchLabel), \($0.ruleDisplay)" }

        lines += ["", "## Verbal warnings"]
        let warnings = entries.filter { $0.severity == .verbalWarning }
        lines += warnings.isEmpty
            ? ["- none"]
            : warnings.map { "- \($0.subject) — \($0.ruleDisplay), \($0.matchLabel)" }

        lines += ["", "## Notes"]
        let notes = entries.filter { $0.severity == .teamNote || $0.severity == .inspectionConcern }
        lines += notes.isEmpty
            ? ["- none"]
            : notes.map { "- \($0.subject) — \($0.note.isEmpty ? $0.ruleDisplay : $0.note)" }

        return lines.joined(separator: "\n")
    }

    /// The archive format. Quotes are doubled so notes containing commas or
    /// quotation marks survive the round trip into a spreadsheet.
    var exportCSV: String {
        func escape(_ field: String) -> String {
            "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        let header = "subject,severity,rule,match,time,note"
        let rows = entries.map { entry in
            [entry.subject, entry.severity.label, entry.ruleDisplay,
             entry.matchLabel, entry.timeLabel, entry.note]
                .map(escape)
                .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    // MARK: - End of day

    var entriesToday: Int { entries.count }
    var cardsIssued: Int {
        entries.filter { [.yellowCard, .redCard, .disableDQ].contains($0.severity) }.count
    }

    /// Teams whose state follows them into tomorrow — anything carrying a badge.
    var carriesIntoTomorrow: [Team] {
        SampleEvent.teams.filter { !badge(for: $0.number).isEmpty }
    }

    /// Entries saved without a rule attached, surfaced during a break so they
    /// can be finished while there is a minute to do it.
    var unfinishedEntries: [RefEntry] {
        entries.filter { $0.ruleCode.isEmpty }
    }
}
