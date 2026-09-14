//
//  TeamsScreen.swift
//  FRC Head Ref Helper
//
//  Every team at the event. Playoff alliances carrying an entry float above
//  the teams, because an alliance card is the easiest thing to lose track of.
//
//  Search is the system `.searchable` field, so it gets the Liquid Glass
//  search presentation and its keyboard handling for free.
//

#if !os(watchOS)
import SwiftUI

struct TeamsScreen: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        @Bindable var notebook = notebook

        ScrollView {
            GlassEffectContainer(spacing: 7) {
                VStack(spacing: 7) {
                    ForEach(notebook.allianceRows()) { alliance in
                        allianceRow(alliance)
                    }
                    ForEach(notebook.teamRows()) { team in
                        teamRow(team)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(FieldBackdrop())
        .navigationTitle("Teams")
        .searchable(text: $notebook.teamQuery, prompt: "Team number or name")
    }

    /// Gold-tinted glass so an alliance never reads as just another team.
    private func allianceRow(_ alliance: Alliance) -> some View {
        let badge = notebook.badge(for: alliance.label)
        return NavigationLink(value: alliance.label) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(alliance.label)
                        .font(RefFont.text(16, .semibold))
                        .foregroundStyle(.white)
                    Text(alliance.teamList)
                        .font(RefFont.numeric(12.5, .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !badge.isEmpty {
                    StatusBadge(text: badge.text,
                                background: badge.background,
                                foreground: badge.foreground)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(minHeight: 62)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(.regular.tint(RefColor.gold.opacity(0.22)).interactive(), radius: RefRadius.card)
    }

    private func teamRow(_ team: Team) -> some View {
        let badge = notebook.badge(for: team.number)
        return NavigationLink(value: team.number) {
            HStack(spacing: 14) {
                TeamAvatarView(team: team.number)

                Text(team.number)
                    .font(RefFont.numeric(24, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, alignment: .leading)

                Text(team.name)
                    .font(RefFont.text(14))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !badge.isEmpty {
                    StatusBadge(text: badge.text,
                                background: badge.background,
                                foreground: badge.foreground)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(minHeight: 62)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(.regular.interactive(), radius: RefRadius.card)
    }
}
#endif
