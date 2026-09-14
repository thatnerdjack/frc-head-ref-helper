//
//  EventPickerScreen.swift
//  FRC Head Ref Helper
//
//  Pick which event the notebook is working. Reached from Settings.
//

#if !os(watchOS)
import SwiftUI

struct EventPickerScreen: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        @Bindable var notebook = notebook

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Events you have opened before. Tap one to fill in its code.")
                    .font(RefFont.text(14))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.bottom, 16)

                GlassEffectContainer(spacing: 7) {
                    VStack(spacing: 7) {
                        ForEach(notebook.eventRows()) { event in
                            eventRow(event)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(FieldBackdrop())
        .navigationTitle("Recent events")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $notebook.eventQuery, prompt: "Event name or code")
    }

    private func eventRow(_ event: RefEvent) -> some View {
        let isCurrent = event.code == notebook.eventCode

        return Button {
            // Fills the code in rather than pretending to load a schedule —
            // the network clients are still to be written.
            notebook.eventCodeDraft = event.code.tbaKey
            notebook.applyEventCode()
            notebook.settingsPath.removeAll()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.name)
                        .font(RefFont.text(16, .semibold))
                        .foregroundStyle(.white)
                    Text(event.when)
                        .font(RefFont.text(13))
                        .foregroundStyle(.white.opacity(0.72))
                    Text("\(event.code.tbaKey) · \(event.teamCount)")
                        .font(RefFont.numeric(12, .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    StatusBadge(text: "LOADED",
                                background: RefColor.gold,
                                foreground: Color(hex: 0x17140A))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: 70)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(isCurrent ? .regular.tint(RefColor.gold.opacity(0.26)).interactive() : .regular.interactive(),
                   radius: RefRadius.card)
    }
}
#endif
