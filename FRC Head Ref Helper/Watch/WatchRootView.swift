//
//  WatchRootView.swift
//  FRC Head Ref Helper
//
//  The watch answers the two questions a head referee asks without taking
//  their eyes off the field for long: how much time is left, and who is out
//  there. Logging still happens on the phone, where the rule list lives.
//
//  Three pages, swipeable with the crown:
//    1. Clock    — time left in the match, or the countdown to the next thing.
//    2. On field — who is playing, tappable through to a team's record.
//    3. Next up  — what is queued, and who has not turned up for it.
//
//  The whole watch app is ONE surface: a single `FieldBackdrop` behind every
//  page, glass cards on top of it, and one type ramp (`WatchFont`). The first
//  pass gave each page its own background tint — gold, then red, then blue —
//  which read as three unrelated apps stacked on a crown scroll rather than
//  three views of one field.
//

#if os(watchOS)
import SwiftUI

struct WatchRootView: View {
    @Environment(Notebook.self) private var notebook

    /// Which page the crown is on. Only bound so that the debug launch
    /// argument below can open one directly; nothing else writes it.
    @State private var page: WatchPage = .clock

    enum WatchPage: Int, Hashable { case clock, field, next }

    var body: some View {
        @Bindable var notebook = notebook

        // One backdrop for all three pages AND the pushed team page. It is the
        // same artwork the phone draws, so the wrist and the pocket look like
        // one app; the only thing it varies on is whether the field is stopped.
        //
        // Layered UNDER the stack rather than handed to the view-builder form
        // of `containerBackground`, which renders nothing here: the paging
        // container proposes no size to that content, so `FieldBackdrop`'s
        // GeometryReader collapses and the screen comes back pure black.
        // `.clear` on each container lets this one show through instead.
        ZStack {
            FieldBackdrop(style: notebook.fieldState == .paused ? .paused : .field)

            NavigationStack(path: $notebook.watchPath) {
                TabView(selection: $page) {
                    WatchClockPage().tag(WatchPage.clock)
                    WatchFieldPage().tag(WatchPage.field)
                    WatchNextPage().tag(WatchPage.next)
                }
                .tabViewStyle(.verticalPage)
                .containerBackground(.clear, for: .tabView)
                .navigationDestination(for: String.self) { subject in
                    WatchTeamPage(subject: subject)
                }
            }
        }
        .tint(RefColor.goldPale)
        #if DEBUG
        // The watch counterpart of the phone's `-refScreen`: the crown cannot
        // be driven from `simctl`, so screenshots of pages 2 and 3 need a way
        // in from the command line.
        //
        //     xcrun simctl launch <watch> \
        //         me.jackdoherty.FRC-Head-Ref-Helper.watchkitapp \
        //         -watchPage 2 -watchTeam 8341
        //
        // Compiled out of release builds.
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag),
                      arguments.index(after: index) < arguments.endIndex else { return nil }
                return arguments[arguments.index(after: index)]
            }
            if let raw = value(after: "-watchPage").flatMap(Int.init),
               let requested = WatchPage(rawValue: raw) {
                page = requested
            }
            if let team = value(after: "-watchTeam") {
                notebook.watchPath = [team]
            }
        }
        #endif
    }
}

// MARK: - What the clock is counting to

extension Notebook {
    /// When the clock the watch is showing reaches zero, or nil when nothing
    /// is running.
    ///
    /// Every branch returns a date anchored to something FIXED — the match's
    /// actual start plus the match length, the timeout's own deadline, the
    /// next match's scheduled start. Deliberately never `now + secondsRemaining`:
    /// that expression moves by the truncated fraction of a second on every
    /// tick, and this project already shipped that bug once in the Live
    /// Activity (see `Notebook.countdownEnd`). Here it would also defeat the
    /// point of a self-ticking `Text`, which needs a date that holds still.
    ///
    /// Lives in the watch's own file, mirroring `countdownEnd`, because that
    /// one is compiled only for iOS — ActivityKit is not on the wrist.
    var watchCountdownEnd: Date? {
        if fieldState == .paused || arenaState?.isTimeout == true {
            return timeoutEndsAt
        }
        if isMatchRunning, matchSecondsRemaining != nil,
           let started = currentMatch?.actualStart {
            return started.addingTimeInterval(Self.matchLength)
        }
        return nextMatch?.scheduledStart
    }

    /// The colour the field's current state is spoken in, used for the clock
    /// digits, the state dot and the glass tint so they cannot disagree.
    var watchStateColor: Color {
        if fieldState == .paused || arenaState?.isTimeout == true { return RefColor.goldBright }
        return isMatchRunning ? RefColor.live : RefColor.goldPale
    }
}

/// A countdown that ticks itself.
///
/// The first pass formatted the remaining seconds into a `String` and leaned on
/// `Notebook`'s 1 Hz ticker to re-render it. That ticker only runs while the
/// watch app is in the foreground, so the clock FROZE the moment the wrist
/// dropped — which is precisely when a referee raises it again to check. This
/// is a correctness bug, not a styling one.
///
/// `Text(timerInterval:)` hands the countdown to the system, which keeps it
/// running while the app is inactive and in the always-on dimmed state.
struct WatchCountdownText: View {
    let end: Date?

    var body: some View {
        if let end {
            // The range is what bounds the timer, and `ClosedRange` traps if
            // the upper bound is earlier than the lower. An overdue clock is
            // normal here — an event running behind schedule has a next match
            // whose scheduled start is already past — so it is clamped rather
            // than assumed away, the same way `Notebook.clock(_:)` clamps.
            //
            // `now` is read ONCE and reused: comparing against `Date.now` and
            // then building the range from a second `Date.now` leaves a window,
            // however small, in which the clock crosses `end` between the two
            // reads and the range that was just proven valid is not.
            let now = Date.now
            if end > now {
                Text(timerInterval: now...end, countsDown: true, showsHours: false)
            } else {
                Text("0:00")
            }
        } else {
            // No clock running is NOT the same as zero. `timeoutEndsAt` is
            // documented as nil precisely so the UI can say "no clock" instead
            // of inventing a countdown, so this stays an em-dash even when the
            // label beside it reads TIMEOUT.
            Text("—")
        }
    }
}

// MARK: - Page 1: the clock

/// The headline number. During a match this is an estimate of time remaining,
/// derived from when the match actually started — FMS is the only authority on
/// match time, so this is labelled as unofficial rather than pretending.
struct WatchClockPage: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        // The clock is one object, not four stacked labels: a single glass
        // card carries the state, the number, the match and the footnote, so
        // the page has a shape instead of floating text.
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(notebook.watchStateColor)
                        .frame(width: 6, height: 6)
                    Text(notebook.primaryClock.label)
                        .font(WatchFont.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }

                WatchCountdownText(end: notebook.watchCountdownEnd)
                    .font(WatchFont.clock)
                    .foregroundStyle(notebook.watchStateColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if let match = notebook.currentMatch {
                    Text(match.key.display)
                        .font(WatchFont.matchCode)
                        .foregroundStyle(.white)
                }

                if notebook.isMatchRunning {
                    Text("unofficial")
                        .font(WatchFont.caption)
                        .foregroundStyle(.white.opacity(0.45))
                } else if let next = notebook.nextMatch {
                    Text("then \(next.key.short)")
                        .font(WatchFont.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            // Tinted, but NOT `.interactive()`: nothing on this page is
            // tappable, and interactive glass would promise a press that does
            // not happen.
            .glassCard(.regular.tint(notebook.watchStateColor.opacity(0.20)),
                       radius: RefRadius.card)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Page 2: who is on the field

struct WatchFieldPage: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        List {
            if let match = notebook.currentMatch {
                Section {
                    ForEach(match.onField, id: \.self) { number in
                        WatchTeamRow(number: number,
                                     color: match.color(of: number),
                                     badge: notebook.shortBadge(for: number),
                                     isMissing: match.missingTeams.contains(number))
                    }
                } header: {
                    WatchSectionHeader(match.key.short,
                                       trailing: notebook.fieldState.label,
                                       trailingColor: notebook.watchStateColor)
                }
            } else {
                WatchEmptyRow("No match on the field")
            }
        }
        .listStyle(.carousel)
    }
}

// MARK: - Page 3: what is next

struct WatchNextPage: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        List {
            if let next = notebook.nextMatch {
                Section {
                    // Queue state is the thing a head ref is asked about most
                    // between matches, so it leads this page.
                    WatchStatRow("Queue",
                                 value: Text(next.queueStatus.label),
                                 valueColor: next.queueStatus.color)
                    WatchStatRow("Starts in",
                                 value: WatchCountdownText(end: next.scheduledStart))
                    if let behind = notebook.minutesBehindSchedule, behind > 0 {
                        WatchStatRow("Running",
                                     value: Text("\(behind) min late"),
                                     valueColor: RefColor.goldPale)
                    }
                } header: {
                    WatchSectionHeader(next.key.display)
                }

                if !next.missingTeams.isEmpty {
                    Section {
                        ForEach(next.missingTeams, id: \.self) { team in
                            WatchTeamRow(number: team,
                                         color: next.color(of: team),
                                         badge: notebook.shortBadge(for: team),
                                         isMissing: true)
                        }
                    } header: {
                        WatchSectionHeader("Not at the field")
                    }
                }

                Section {
                    ForEach(next.onField, id: \.self) { number in
                        WatchTeamRow(number: number,
                                     color: next.color(of: number),
                                     badge: notebook.shortBadge(for: number),
                                     isMissing: false)
                    }
                } header: {
                    WatchSectionHeader("Lineup")
                }
            } else {
                WatchEmptyRow("Nothing queued")
            }
        }
        .listStyle(.carousel)
    }
}

// MARK: - Team record

/// A team's record, read-only. Enough to answer "have I already spoken to
/// them about this?" without reaching for the phone.
struct WatchTeamPage: View {
    @Environment(Notebook.self) private var notebook
    let subject: String

    var body: some View {
        List {
            Section {
                // Three counters across one card rather than three rows: they
                // are read together ("any cards? how many warnings?"), and the
                // phone's team page groups them the same way.
                let counts = notebook.counts(for: subject)
                HStack(spacing: 0) {
                    WatchCount(value: counts.warnings, label: "Warn")
                    WatchCount(value: counts.yellow + counts.red, label: "Cards",
                               isHighlighted: counts.yellow + counts.red > 0)
                    WatchCount(value: counts.notes, label: "Notes")
                }
                .padding(.vertical, 10)
                .glassCard(.regular, radius: RefRadius.card)
                .watchCardRow()
            } header: {
                WatchSectionHeader(SampleEvent.team(subject)?.name ?? subject)
            }

            if let hint = notebook.escalationHint(for: subject) {
                Section {
                    Text(hint)
                        .font(WatchFont.label)
                        .foregroundStyle(RefColor.goldPale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .glassCard(.regular.tint(RefColor.gold.opacity(0.24)),
                                   radius: RefRadius.row)
                        .watchCardRow()
                } header: {
                    WatchSectionHeader("Escalation")
                }
            }

            Section {
                let entries = notebook.entries(for: subject)
                if entries.isEmpty {
                    WatchEmptyRow("Nothing logged")
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(entry.severity.color)
                                    .frame(width: 7, height: 7)
                                Text(entry.severity.short)
                                    .font(WatchFont.value)
                                    .foregroundStyle(.white)
                                Spacer(minLength: 0)
                                Text(entry.matchLabel)
                                    .font(WatchFont.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Text(entry.ruleCode)
                                .font(WatchFont.caption)
                                .foregroundStyle(RefColor.goldPale)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .glassCard(.regular, radius: RefRadius.row)
                        .watchCardRow()
                    }
                }
            } header: {
                WatchSectionHeader("This event")
            }
        }
        .listStyle(.carousel)
        .navigationTitle(subject)
        // Same reason as the TabView: the navigation container paints its own
        // fill over the root backdrop unless it is told not to.
        .containerBackground(.clear, for: .navigation)
    }
}

// MARK: - Rows

/// A team on the watch. A NavigationLink, so a team can be tapped through to
/// its record — the first pass showed numbers you could not act on.
struct WatchTeamRow: View {
    let number: String
    let color: AllianceColor
    let badge: String
    let isMissing: Bool

    var body: some View {
        NavigationLink(value: number) {
            HStack(spacing: 8) {
                AllianceBar(color: color.watchBar, height: 22, width: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(number)
                        .font(WatchFont.teamNumber)
                        .foregroundStyle(.white)
                    if isMissing {
                        Text("late")
                            .font(WatchFont.caption)
                            .foregroundStyle(RefColor.goldPale)
                    }
                }

                Spacer(minLength: 0)

                if !badge.isEmpty {
                    Text(badge)
                        .font(WatchFont.badge)
                        .foregroundStyle(RefColor.badgeInk(for: badge))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RefColor.badgeTint(for: badge), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // The alliance tint IS the row background here, the way the phone
            // tints its team rows. `.interactive()` is chained because this
            // row pushes a page: tinted glass that does not react to the press
            // reads as a dead label.
            .glassCard(.regular.tint(color.watchBar.opacity(0.26)).interactive(),
                       radius: RefRadius.row)
        }
        // The system link chrome would draw its own grey capsule underneath
        // our glass, and its chevron costs width the team number needs.
        .buttonStyle(.plain)
        .watchCardRow()
    }
}

/// A labelled value on the "next up" page. `value` is a view rather than a
/// String so a self-ticking countdown can sit in the same row shape as static
/// text, instead of needing a second row type.
struct WatchStatRow<Value: View>: View {
    let label: String
    let value: Value
    var valueColor: Color = .white

    init(_ label: String, value: Value, valueColor: Color = .white) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(WatchFont.label)
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 4)
            value
                .font(WatchFont.value)
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .glassCard(.regular, radius: RefRadius.row)
        .watchCardRow()
    }
}

/// One of the three counters on a team's record.
struct WatchCount: View {
    let value: Int
    let label: String
    var isHighlighted: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(WatchFont.matchCode)
                .foregroundStyle(isHighlighted ? RefColor.goldPale : .white)
            Text(label)
                .font(WatchFont.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}

/// The quiet all-caps label heading a section, matching the phone's
/// `SectionLabel` but built on the watch ramp — `SectionLabel` asks `RefFont`
/// for 12pt, which lands on an iOS-calibrated text style.
struct WatchSectionHeader: View {
    let title: String
    var trailing: String?
    var trailingColor: Color = .white

    init(_ title: String, trailing: String? = nil, trailingColor: Color = .white) {
        self.title = title
        self.trailing = trailing
        self.trailingColor = trailingColor
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(WatchFont.caption)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            if let trailing {
                Spacer(minLength: 4)
                Text(trailing)
                    .font(WatchFont.badge)
                    .foregroundStyle(trailingColor)
            }
        }
        .textCase(nil)
    }
}

/// "Nothing here" in the same card shape as the rows it replaces, so an empty
/// page still looks composed rather than broken.
struct WatchEmptyRow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(WatchFont.label)
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .glassCard(.regular, radius: RefRadius.row)
            .watchCardRow()
    }
}

extension View {
    /// Hands a List row over to its content: the carousel style's own grey
    /// capsule is cleared so the glass card underneath is the only background,
    /// and the default insets are replaced with a hairline gap so adjacent
    /// cards read as separate objects.
    func watchCardRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
    }
}
#endif
