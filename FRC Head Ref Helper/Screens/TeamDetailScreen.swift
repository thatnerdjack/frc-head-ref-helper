//
//  TeamDetailScreen.swift
//  FRC Head Ref Helper
//
//  One team's (or alliance's) record at this event. History lives here rather
//  than in a global log, so it answers the question actually asked on the
//  field: "what has THIS team already done today?"
//

#if !os(watchOS)
import SwiftUI

struct TeamDetailScreen: View {
    @Environment(Notebook.self) private var notebook

    /// Passed by the NavigationStack rather than read from shared state, so
    /// the pushed screen always shows what was tapped.
    let subject: String

    private var alliance: Alliance? { SampleEvent.alliance(labelled: subject) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(subject)
                    .font(RefFont.numeric(62, .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.bottom, 6)

                Text(displayName)
                    .font(RefFont.text(17, .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.bottom, 4)

                Text(metaLine)
                    .font(RefFont.numeric(13))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 20)

                statTiles.padding(.bottom, 14)

                RobotPhotoStrip(team: subject)

                if let hint = notebook.escalationHint(for: subject) {
                    escalationCard(hint).padding(.bottom, 20)
                }

                SectionLabel(text: "THIS EVENT").padding(.bottom, 10)

                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(notebook.entries(for: subject)) { entry in
                            entryCard(entry)
                        }
                    }
                }
                .padding(.bottom, 18)

                Button("New entry for \(subject)") {
                    notebook.selectedSubject = subject
                    notebook.startCompose()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(RefColor.gold)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(FieldBackdrop())
        .navigationTitle(subject)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var displayName: String {
        alliance != nil ? "Playoff alliance" : (SampleEvent.team(subject)?.name ?? "")
    }

    private var metaLine: String {
        if let alliance {
            return "Seed \(alliance.seed) · \(alliance.teams.joined(separator: ", "))"
        }
        // Placeholder standings from the design; replace with frc.events data.
        return "Rank 14 · 5 quals played · next Q42 blue 3"
    }

    private var statTiles: some View {
        let counts = notebook.counts(for: subject)
        let stats = [
            ("Verbal warnings", counts.warnings),
            ("Cards", counts.yellow + counts.red),
            ("Notes", counts.notes),
        ]
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(stats, id: \.0) { label, value in
                    StatTile(value: "\(value)", label: label)
                }
            }
        }
    }

    /// Gold, above the history, because it is advice about the NEXT call rather
    /// than a record of a past one.
    private func escalationCard(_ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ESCALATION")
                .font(RefFont.numeric(12, .semibold))
                .foregroundStyle(RefColor.goldPale)
            Text(hint)
                .font(RefFont.text(15))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .glassCard(.regular.tint(RefColor.gold.opacity(0.26)), radius: 26)
    }

    private func entryCard(_ entry: RefEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(entry.severity.color)
                    .frame(width: 12, height: 12)

                Text(entry.severity.label)
                    .font(RefFont.text(15, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(entry.matchLabel) · \(entry.timeLabel)")
                    .font(RefFont.numeric(12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.bottom, 8)

            Text(entry.ruleDisplay)
                .font(RefFont.numeric(14, .medium))
                .foregroundStyle(RefColor.goldPale)

            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(RefFont.text(14))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .glassCard(radius: RefRadius.card)
    }
}
#endif
