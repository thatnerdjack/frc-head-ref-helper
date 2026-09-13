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

#if os(watchOS)
import SwiftUI

struct WatchRootView: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        @Bindable var notebook = notebook

        NavigationStack(path: $notebook.teamsPath) {
            TabView {
                WatchClockPage()
                WatchFieldPage()
                WatchNextPage()
            }
            .tabViewStyle(.verticalPage)
            .containerBackground(RefColor.void.gradient, for: .tabView)
            .navigationDestination(for: String.self) { subject in
                WatchTeamPage(subject: subject)
            }
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
        VStack(spacing: 2) {
            Text(notebook.primaryClock.label)
                .font(RefFont.text(11, .semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text(notebook.primaryClock.value)
                .font(.system(size: 54, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(notebook.isMatchRunning ? RefColor.live : RefColor.goldPale)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText(countsDown: true))
                .animation(.default, value: notebook.primaryClock.value)

            if let match = notebook.currentMatch {
                Text(match.key.display)
                    .font(RefFont.numeric(15, .semibold))
                    .foregroundStyle(.white)
            }

            if notebook.isMatchRunning {
                Text("unofficial")
                    .font(RefFont.text(10))
                    .foregroundStyle(.white.opacity(0.45))
            } else if let next = notebook.nextMatch {
                Text("then \(next.key.short)")
                    .font(RefFont.text(12, .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(
            (notebook.isMatchRunning ? RefColor.live : RefColor.gold).opacity(0.35).gradient,
            for: .tabView
        )
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
                    HStack {
                        Text(match.key.short)
                        Spacer()
                        Text(notebook.fieldState.label)
                            .foregroundStyle(notebook.fieldState == .live
                                             ? RefColor.live : RefColor.goldPale)
                    }
                }
            } else {
                Text("No match on the field").foregroundStyle(.secondary)
            }
        }
        .listStyle(.carousel)
        .containerBackground(RefColor.redBar.opacity(0.25).gradient, for: .tabView)
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
                    LabeledContent("Queue") {
                        Text(next.queueStatus.label)
                            .foregroundStyle(next.queueStatus.color)
                    }
                    LabeledContent("Starts in") {
                        Text(notebook.nextMatchClock).monospacedDigit()
                    }
                    if let behind = notebook.minutesBehindSchedule, behind > 0 {
                        LabeledContent("Running") { Text("\(behind) min late") }
                    }
                } header: {
                    Text(next.key.display)
                }

                if !next.missingTeams.isEmpty {
                    Section("Not at the field") {
                        ForEach(next.missingTeams, id: \.self) { team in
                            WatchTeamRow(number: team,
                                         color: next.color(of: team),
                                         badge: notebook.shortBadge(for: team),
                                         isMissing: true)
                        }
                    }
                }

                Section("Lineup") {
                    ForEach(next.onField, id: \.self) { number in
                        WatchTeamRow(number: number,
                                     color: next.color(of: number),
                                     badge: notebook.shortBadge(for: number),
                                     isMissing: false)
                    }
                }
            } else {
                Text("Nothing queued").foregroundStyle(.secondary)
            }
        }
        .listStyle(.carousel)
        .containerBackground(RefColor.blueBar.opacity(0.25).gradient, for: .tabView)
    }
}

// MARK: - Shared row

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
                Capsule().fill(color.watchBar).frame(width: 3, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(number)
                        .font(RefFont.numeric(17, .semibold))
                        .foregroundStyle(.white)
                    if isMissing {
                        Text("late")
                            .font(RefFont.text(11, .medium))
                            .foregroundStyle(RefColor.goldPale)
                    }
                }

                Spacer(minLength: 0)

                if !badge.isEmpty {
                    Text(badge)
                        .font(RefFont.numeric(12, .semibold))
                        .foregroundStyle(RefColor.badgeInk(for: badge))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RefColor.badgeTint(for: badge), in: Capsule())
                }
            }
        }
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
                let counts = notebook.counts(for: subject)
                LabeledContent("Warnings") { Text("\(counts.warnings)") }
                LabeledContent("Cards") { Text("\(counts.yellow + counts.red)") }
                LabeledContent("Notes") { Text("\(counts.notes)") }
            } header: {
                Text(SampleEvent.team(subject)?.name ?? subject)
            }

            if let hint = notebook.escalationHint(for: subject) {
                Section("Escalation") {
                    Text(hint)
                        .font(RefFont.text(13))
                        .foregroundStyle(RefColor.goldPale)
                }
            }

            let entries = notebook.entries(for: subject)
            if entries.isEmpty {
                Section("This event") {
                    Text("Nothing logged").foregroundStyle(.secondary)
                }
            } else {
                Section("This event") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle().fill(entry.severity.color).frame(width: 8, height: 8)
                                Text(entry.severity.short)
                                    .font(RefFont.text(13, .semibold))
                                Spacer(minLength: 0)
                                Text(entry.matchLabel)
                                    .font(RefFont.numeric(11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.ruleCode)
                                .font(RefFont.numeric(12, .medium))
                                .foregroundStyle(RefColor.goldPale)
                        }
                    }
                }
            }
        }
        .navigationTitle(subject)
    }
}
#endif
