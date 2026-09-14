//
//  DayCompleteScreen.swift
//  FRC Head Ref Helper
//
//  The field is done for the day. The content that earns its place is
//  "carries into tomorrow": the cards and warnings still live when quals
//  resume in the morning.
//

#if !os(watchOS)
import SwiftUI

struct DayCompleteScreen: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Day 1 complete")
                    .font(RefFont.text(40, .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 6)

                Text("Quals resume 8:30 tomorrow. Playoffs after lunch.")
                    .font(RefFont.text(15))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.bottom, 20)

                statTiles.padding(.bottom, 14)

                SectionLabel(text: "CARRIES INTO TOMORROW", opacity: 0.72)
                    .padding(.bottom, 10)

                GlassEffectContainer(spacing: 5) {
                    VStack(spacing: 5) {
                        ForEach(notebook.carriesIntoTomorrow) { team in
                            carryRow(team)
                        }
                    }
                }
                .padding(.bottom, 18)

                HStack(spacing: 8) {
                    Button("Send day summary") {
                        notebook.selectedTab = .settings
                    }
                    .buttonStyle(.glassProminent)
                    .tint(RefColor.gold)

                    Button("Keep logging") {
                        notebook.fieldState = .live
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(FieldBackdrop(style: .dayComplete))
        .navigationTitle("\(notebook.eventName) · Day 1")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statTiles: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                StatTile(value: "\(notebook.qualsPlayed)", label: "Quals played")
                StatTile(value: "\(notebook.entriesToday)", label: "Entries today")
                StatTile(value: "\(notebook.cardsIssued)",
                         label: notebook.cardsIssued == 1 ? "Card issued" : "Cards issued",
                         isHighlighted: notebook.cardsIssued > 0)
            }
        }
    }

    private func carryRow(_ team: Team) -> some View {
        let badge = notebook.badge(for: team.number)
        return NavigationLink(value: team.number) {
            HStack(spacing: 12) {
                TeamAvatarView(team: team.number)
                Text(team.number)
                    .font(RefFont.numeric(22, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, alignment: .leading)
                Text(team.name)
                    .font(RefFont.text(13.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !badge.isEmpty {
                    StatusBadge(text: badge.text,
                                background: badge.background,
                                foreground: badge.foreground)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(minHeight: 62)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(.regular.interactive(), radius: RefRadius.row)
    }
}
#endif
