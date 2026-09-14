//
//  MatchLiveActivity.swift
//  RefWidgets
//
//  The match Live Activity: what is on the field, how long is left, and which
//  of those teams is already carrying something.
//
//  The whole point is that a head referee can answer "how long have I got" and
//  "who am I watching" from the Dynamic Island without unlocking the phone.
//  So the compact presentations lead with the clock, and the expanded one
//  leads with the two alliances and their card state.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct MatchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchActivityAttributes.self) { context in
            LockScreenMatchView(context: context)
                .activityBackgroundTint(RefColor.void.opacity(0.85))
                .activitySystemActionForegroundColor(RefColor.gold)
        } dynamicIsland: { context in
            DynamicIsland {
                // The leading/trailing regions are narrow — they sit either
                // side of the camera — so they hold only the match and clock.
                // Both are explicitly constrained: unconstrained text here is
                // clipped by the island's rounded edge rather than scaled, and
                // whatever the trailing side reserves comes out of the leading
                // side's width.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.state.matchShort)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(context.state.stateLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(state: context.state)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent(context.state))
                        .lineLimit(1)
                        .frame(minWidth: 62, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        AllianceRow(teams: context.state.red, color: .red)
                        AllianceRow(teams: context.state.blue, color: .blue)
                        StatusLine(state: context.state)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Text(context.state.matchShort)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent(context.state))
                    .lineLimit(1)
            } compactTrailing: {
                CountdownText(state: context.state)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent(context.state))
                    .frame(minWidth: 48, maxWidth: 56, alignment: .trailing)
            } minimal: {
                // What shows when another app's Live Activity takes precedence.
                // This is a ~24pt circle, so digits do not fit — a countdown
                // RING does, it ticks itself from the same end date, and it
                // still answers "how long have I got" at a glance.
                MinimalCountdown(state: context.state, tint: accent(context.state))
            }
            .keylineTint(accent(context.state))
        }
    }

    /// Green while a match is actually being played, gold when waiting.
    private func accent(_ state: MatchActivityAttributes.ContentState) -> Color {
        state.isMatchRunning ? RefColor.live : RefColor.gold
    }
}

// MARK: - Minimal presentation

/// The Dynamic Island's smallest form, used when another Live Activity is in
/// front of ours. A circular countdown driven by the same end date, so it
/// ticks without the app pushing anything.
struct MinimalCountdown: View {
    let state: MatchActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        // `end > .now` is not redundant with the app's own guard: ActivityKit
        // replays the last persisted ContentState, which can outlive both the
        // app process and the build that wrote it.
        if let end = state.countdownEnd, end > .now {
            ProgressView(timerInterval: Date.now...end, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .tint(tint)
        } else {
            // No clock running. A dot in the state colour still says which
            // event surface this is, without implying a countdown.
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Countdown

/// Renders the clock from an end date so WidgetKit ticks it down on its own,
/// rather than the app pushing an update every second.
struct CountdownText: View {
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        if let end = state.countdownEnd, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
                .multilineTextAlignment(.center)
        } else {
            Text("—")
        }
    }
}

// MARK: - Lock screen / banner

struct LockScreenMatchView: View {
    let context: ActivityViewContext<MatchActivityAttributes>

    private var state: MatchActivityAttributes.ContentState { context.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Event and state on one quiet line, so the row below belongs
            // entirely to the two numbers that matter.
            HStack {
                Text(context.attributes.eventName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 8)
                Text(state.stateLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Match number hard left, clock hard right — both on the same
            // baseline, so neither floats.
            HStack(alignment: .firstTextBaseline) {
                Text(state.matchLabel)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                // A timer's width changes as it ticks, and left to size itself
                // it degrades to "1:--". Reserving the width keeps the seconds.
                CountdownText(state: state)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.isMatchRunning ? RefColor.live : RefColor.goldPale)
                    .lineLimit(1)
                    .frame(minWidth: 104, alignment: .trailing)
            }

            // Red above blue, full width, at a size readable at arm's length.
            VStack(spacing: 6) {
                AllianceRow(teams: state.red, color: .red, prominent: true)
                AllianceRow(teams: state.blue, color: .blue, prominent: true)
            }

            StatusLine(state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Shared pieces

/// One alliance across the full width — three teams side by side, in the order
/// they appear on the field. `prominent` is the lock-screen size, where there
/// is room to make the numbers properly legible.
struct AllianceRow: View {
    let teams: [TeamChip]
    let color: LiveAllianceColor
    var prominent: Bool = false

    private var numberFont: Font {
        prominent
            ? .system(size: 20, weight: .semibold, design: .rounded)
            : .caption.weight(.semibold)
    }

    var body: some View {
        HStack(spacing: prominent ? 8 : 6) {
            Capsule()
                .fill(color.bar)
                .frame(width: prominent ? 4 : 3, height: prominent ? 22 : 14)
                .padding(.leading, prominent ? 0 : 2)

            ForEach(teams) { team in
                HStack(spacing: 4) {
                    Text(team.number)
                        .font(numberFont)
                        .monospacedDigit()
                        .foregroundStyle(color.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if team.isFlagged {
                        Text(team.badge)
                            .font(.system(size: prominent ? 11 : 9, weight: .bold))
                            .foregroundStyle(RefColor.badgeInk(for: team.badge))
                            .padding(.horizontal, prominent ? 5 : 3)
                            .padding(.vertical, prominent ? 2 : 1)
                            .background(RefColor.badgeTint(for: team.badge), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Queue state and anyone not at the field. Deliberately not a list of flags —
/// every team already carries its own badge in the rows above.
struct StatusLine: View {
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if let queue = state.queueLabel {
                label(queue, systemImage: "clock")
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !state.missingTeams.isEmpty {
                label("Missing \(state.missingTeams.joined(separator: ", "))",
                      systemImage: "person.fill.questionmark")
                    .foregroundStyle(RefColor.goldPale)
            }
            Spacer(minLength: 0)
        }
    }

    private func label(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
    }
}

/// The extension has no access to the app's `AllianceColor`, which carries
/// app-only types, so alliance colour is expressed locally against the shared
/// palette in `RefTheme`.
enum LiveAllianceColor {
    case red, blue

    var bar: Color { self == .red ? RefColor.redBar : RefColor.blueBar }
    var text: Color { self == .red ? RefColor.redText : RefColor.blueText }
}
