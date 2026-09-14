//
//  Notebook.swift
//  FRC Head Ref Helper
//
//  The app's state: which screen is up, what the compose sheet currently
//  holds, the settings, the schedule, the clock tick — and the lifecycle that
//  binds all of it to the store.
//
//  Everything DERIVED from that state lives in the `Notebook+*.swift` files
//  beside this one — the team record, the derived lists, rule search, the
//  clocks, the schedule reads, the Live Activity, the exports and the
//  end-of-day tallies. Only `context` and the lifecycle helpers are private to
//  this file; an extension can read any of the state above.
//
//  The rules those files encode are the ones a head ref actually has to hold
//  in their head, so they live in one testable place instead of inside views:
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
    /// When the current timeout / field reset ends. Nil when no clock is
    /// running — which is different from "zero", and the UI must say so
    /// rather than invent a countdown.
    ///
    /// A deadline rather than a decrementing counter because a counter is
    /// wrong the moment the app is suspended, and because deriving the Live
    /// Activity's end date from `now` made that date jitter every tick (see
    /// `countdownEnd`).
    var timeoutEndsAt: Date?

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
        adoptUnfiledEntries()
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
                self.syncLiveActivity()
            }
        }
    }

    deinit {
        ticker?.cancel()
        toastDismissal?.cancel()
    }

    /// Files entries written before entries carried an event.
    ///
    /// Reads are scoped by event, so a row left at the default empty key is
    /// invisible — an upgrading referee would open the app to a blank
    /// notebook, which is the worst outcome this app has. An unfiled entry
    /// belongs to whatever event was open when it was written, and the only
    /// event we can still name is the current one.
    private func adoptUnfiledEntries() {
        guard let context else { return }
        let unfiled = (try? context.fetch(
            FetchDescriptor<RefEntry>(predicate: #Predicate { $0.eventKey == "" })
        )) ?? []
        guard !unfiled.isEmpty else { return }
        let key = eventCode.tbaKey
        for entry in unfiled { entry.eventKey = key }
        try? context.save()
    }

    private func seedIfNeeded() {
        guard let context else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<RefEntry>())) ?? 0
        guard existing == 0 else { return }
        for entry in RefEntry.sampleEntries() { context.insert(entry) }
        try? context.save()
    }

    /// Loads this event's entries, newest first.
    ///
    /// Scoping happens HERE and nowhere else. Every derived read — counts,
    /// badges, escalation hints, hot rules, both exports, the day-complete
    /// tallies — goes through `entries`, so one predicate scopes all of them
    /// and there is exactly one place that can be wrong.
    private func reload() {
        guard let context else { return }
        // #Predicate cannot capture self, so the key is bound locally first.
        let key = eventCode.tbaKey
        let descriptor = FetchDescriptor<RefEntry>(
            predicate: #Predicate { $0.eventKey == key },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        entries = (try? context.fetch(descriptor)) ?? []
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
        guard parsed != eventCode else { return }
        eventCode = parsed
        eventCodeDraft = parsed.tbaKey
        // The notebook is per-event, so the loaded entries must change with it.
        // Nothing is deleted — the outgoing event's entries stay in the store
        // and come back when it is selected again.
        reload()
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
        // Arming the clock is the field's job. Until a source does it, the
        // debug cycle stands in — but it sets a real deadline rather than
        // starting a counter that loops forever and reads as a live timeout.
        timeoutEndsAt = fieldState == .paused ? now.addingTimeInterval(204) : nil
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
            eventKey: eventCode.tbaKey,
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

    /// Not private: `recordReplay(of:)` in `Notebook+Schedule.swift` raises a
    /// toast too, and an ARENA FAULT replay is exactly the moment a head ref
    /// needs to be told what just happened to their entries.
    func show(toast message: String) {
        toast = message
        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Shared with `Notebook+Export.swift`, so a saved entry's time and the
    /// export header's time cannot drift into two different formats.
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
