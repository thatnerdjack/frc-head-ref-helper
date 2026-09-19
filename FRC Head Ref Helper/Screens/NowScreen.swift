//
//  NowScreen.swift
//  FRC Head Ref Helper
//
//  Everything on the field, in one card. Under it: how the event is running,
//  and what is queued next — including which teams have not turned up, which
//  is the question a head referee fields most often between matches.
//

#if !os(watchOS)
import SwiftUI

struct NowScreen: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let match = notebook.currentMatch {
                    matchHeader(match).padding(.bottom, 18)

                    GlassEffectContainer(spacing: 5) {
                        VStack(spacing: 5) {
                            ForEach(match.onField, id: \.self) { number in
                                FieldTeamRow(
                                    number: number,
                                    name: SampleEvent.team(number)?.name ?? "",
                                    allianceColor: match.color(of: number),
                                    badge: notebook.badge(for: number),
                                    isMissing: match.missingTeams.contains(number)
                                )
                            }
                        }
                    }
                    .padding(.bottom, 12)
                } else {
                    Text("No match on the field")
                        .font(RefFont.text(17, .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 12)
                }

                if notebook.fieldState == .paused {
                    breakBanner.padding(.bottom, 12)
                }

                if let next = notebook.nextMatch {
                    UpcomingMatchCard(match: next, lead: notebook.nextMatchLeadLabel)
                        .padding(.bottom, 12)
                }

                runningLateCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(FieldBackdrop(style: notebook.fieldState == .paused ? .paused : .field))
        .navigationTitle(notebook.eventName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Tappable in DEBUG only.
                //
                // Cycling live -> paused -> day complete is a stand-in for the
                // field telling us a timeout started, and it is genuinely
                // useful while no source does. Shipping it is another matter: a
                // head referee holding this at an event can put the app into
                // "day complete" with one stray tap on the status pill, and
                // once a real source is driving `fieldState` that tap silently
                // desyncs the app from the field mid-match.
                //
                // `applyDebugLaunchArguments` next door is already compiled out
                // of release; this was the one that got missed. In release the
                // pill is what it looks like — a read-only status indicator.
                #if DEBUG
                Button { notebook.advanceFieldState() } label: { fieldStatePill }
                    .buttonStyle(.glass)
                #else
                fieldStatePill
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect()
                #endif
            }
        }
    }

    /// The status pill's contents. Identical in both builds — only whether it
    /// is wrapped in a Button differs.
    private var fieldStatePill: some View {
        HStack(spacing: 7) {
            if notebook.fieldState == .live {
                Circle().fill(RefColor.live).frame(width: 7, height: 7)
            }
            Text(notebook.fieldState.label).font(RefFont.text(12, .semibold))
        }
    }

    private func matchHeader(_ match: Match) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(match.key.short)
                    .font(RefFont.numeric(46, .semibold))
                    .foregroundStyle(.white)
                Text(notebook.isMatchRunning ? "on field now" : "up now")
                    .font(RefFont.text(15, .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer(minLength: 0)
                if let remaining = notebook.matchSecondsRemaining, notebook.isMatchRunning {
                    Text(notebook.clockText(remaining))
                        .font(RefFont.numeric(28, .semibold))
                        .foregroundStyle(RefColor.goldPale)
                }
            }

            if match.isReplay {
                Label("Replay \(match.key.play) after an arena fault",
                      systemImage: "arrow.counterclockwise")
                    .font(RefFont.text(13, .medium))
                    .foregroundStyle(RefColor.goldPale)
            }
        }
    }

    private var breakBanner: some View {
        HStack(spacing: 16) {
            Text(notebook.breakClock)
                .font(RefFont.numeric(44, .semibold))
                .foregroundStyle(RefColor.breakInk)

            VStack(alignment: .leading, spacing: 2) {
                Text("FIELD PAUSED")
                    .font(RefFont.text(12, .semibold))
                    .foregroundStyle(RefColor.breakInk.opacity(0.72))
                    .padding(.bottom, 3)
                Text("Playoff timeout")
                    .font(RefFont.text(16, .semibold))
                    .foregroundStyle(RefColor.breakInk)
                if let next = notebook.nextMatch {
                    Text("\(next.key.short) queues when it hits zero")
                        .font(RefFont.text(13, .medium))
                        .foregroundStyle(RefColor.breakInk.opacity(0.78))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(RefColor.goldBright,
                    in: RoundedRectangle(cornerRadius: RefRadius.container, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RefRadius.container, style: .continuous)
                .strokeBorder(RefColor.goldEdge, lineWidth: 1)
        )
    }

    /// How far behind the event is running. Comes from comparing scheduled and
    /// actual start times, which both frc.events and Cheesy Arena report.
    @ViewBuilder
    private var runningLateCard: some View {
        if let behind = notebook.minutesBehindSchedule, behind != 0 {
            HStack(spacing: 12) {
                Image(systemName: behind > 0 ? "clock.badge.exclamationmark" : "clock.badge.checkmark")
                    .foregroundStyle(behind > 0 ? RefColor.goldPale : RefColor.live)
                Text(behind > 0
                     ? "Running \(behind) min behind schedule"
                     : "Running \(-behind) min ahead of schedule")
                    .font(RefFont.text(14, .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .glassCard(radius: RefRadius.row)
        }
    }
}

// MARK: - Rows

struct FieldTeamRow: View {
    let number: String
    let name: String
    let allianceColor: AllianceColor
    let badge: TeamBadge
    var isMissing: Bool = false

    var body: some View {
        NavigationLink(value: number) {
            HStack(spacing: 10) {
                AllianceBar(color: allianceColor.bar)
                TeamAvatarView(team: number)

                Text(number)
                    .font(RefFont.numeric(24, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(RefFont.text(13.5))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    if isMissing {
                        Label("Not at the field", systemImage: "exclamationmark.triangle.fill")
                            .font(RefFont.text(11, .semibold))
                            .foregroundStyle(RefColor.goldPale)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !badge.isEmpty {
                    StatusBadge(text: badge.text,
                                background: badge.background,
                                foreground: badge.foreground)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(.regular.interactive(), radius: RefRadius.innerRow)
    }
}

/// The next match. Built around the lineup rather than a label and a lot of
/// empty space: each team is a cell showing its number, its card state and
/// whether it has actually turned up, and every cell is tappable.
struct UpcomingMatchCard: View {
    @Environment(Notebook.self) private var notebook

    let match: Match
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 6) {
                    allianceRow(match.red, color: .red)
                    allianceRow(match.blue, color: .blue)
                }
            }

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .glassCard(radius: RefRadius.container)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lead)
                    .font(RefFont.text(12, .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(match.key.display)
                    .font(RefFont.numeric(26, .semibold))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(text: match.queueStatus.label.uppercased(),
                            background: match.queueStatus.color.opacity(0.9),
                            foreground: match.queueStatus == .onField ? RefColor.liveInk : RefColor.ink)
                if let scheduled = match.scheduledStart {
                    Text(scheduled.formatted(date: .omitted, time: .shortened))
                        .font(RefFont.numeric(13, .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    // MARK: - Lineup

    /// One alliance as three equal cells. A plain HStack rather than a grid:
    /// each cell claims an equal share of the full width, which a LazyVGrid
    /// inside a leading-aligned stack does not.
    private func allianceRow(_ teams: [String], color: AllianceColor) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(color.bar)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                ForEach(teams, id: \.self) { team in
                    teamCell(team, color: color)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func teamCell(_ team: String, color: AllianceColor) -> some View {
        let badge = notebook.badge(for: team)
        let isMissing = match.missingTeams.contains(team)

        return NavigationLink(value: team) {
            VStack(spacing: 2) {
                Text(team)
                    .font(RefFont.numeric(19, .semibold))
                    .foregroundStyle(color.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let name = SampleEvent.team(team)?.name {
                    Text(name)
                        .font(RefFont.text(10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                // A team's state travels with it into the next match, which is
                // exactly what you want to know before it starts.
                HStack(spacing: 4) {
                    if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(RefColor.goldPale)
                    }
                    if !badge.isEmpty {
                        Circle()
                            .fill(badge.background)
                            .frame(width: 6, height: 6)
                        Text(notebook.shortBadge(for: team))
                            .font(RefFont.numeric(10, .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if !isMissing && badge.isEmpty {
                        // Invisible, and deliberately so: it reserves the
                        // status line's height for a team with nothing
                        // against it. An empty HStack contributes no height,
                        // which left clean cells shorter than flagged ones.
                        Text("0")
                            .font(RefFont.numeric(10, .semibold))
                            .hidden()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(isMissing ? .regular.tint(RefColor.gold.opacity(0.28)).interactive() : .regular.interactive(),
                   radius: 14)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        let flagged = match.onField.filter { !notebook.badge(for: $0).isEmpty }

        if !match.missingTeams.isEmpty || !flagged.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !match.missingTeams.isEmpty {
                    Label("Not at the field: \(match.missingTeams.joined(separator: ", "))",
                          systemImage: "person.fill.questionmark")
                        .font(RefFont.text(13, .medium))
                        .foregroundStyle(RefColor.goldPale)
                }
                if !flagged.isEmpty {
                    // Spell out what each one carries: a yellow card and two
                    // verbal warnings call for different handling.
                    let summary = flagged
                        .map { "\($0) \(notebook.shortBadge(for: $0))" }
                        .joined(separator: " · ")
                    Label("Flagged: \(summary)", systemImage: "flag.fill")
                        .font(RefFont.text(13, .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

#endif
