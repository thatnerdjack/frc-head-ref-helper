//
//  SettingsScreen.swift
//  FRC Head Ref Helper
//
//  Which event you're working, where data comes from, how the notebook
//  behaves, and getting the day's log back out.
//
//  Sources are independently switchable, because that is how they are used in
//  practice — frc.events for the official schedule, Nexus for queueing, Cheesy
//  Arena for what is on the field right now. The Coverage section then shows
//  which source will actually answer each question, so a gap is visible before
//  the event starts rather than during it.
//

#if !os(watchOS)
import SwiftUI

struct SettingsScreen: View {
    @Environment(Notebook.self) private var notebook
    @FocusState private var eventCodeFocused: Bool

    var body: some View {
        @Bindable var notebook = notebook

        Form {
            eventSection
            sourcesSection
            coverageSection

            Section("Notebook") {
                Toggle("Escalation hints", isOn: $notebook.escalationHintsEnabled)
                Toggle("Learn my hot rules", isOn: $notebook.hotRulesFirst)
                Toggle("Watch and live activity", isOn: $notebook.watchEnabled)
            }

            exportSection

            Section {
                NavigationLink("Cheesy Arena connection", value: Notebook.SettingsRoute.arena)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Entries stay on your decice. Nothing is sent to the arena.")
                    // Which manual these rules came from. A referee needs to
                    // know this before trusting a rule number.
                    Text("Rules current as of \(RuleCatalog.manualVersion).")
                        .fontWeight(.medium)
                    Text("\(RuleCatalog.all.count) rules loaded.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FieldBackdrop())
        .navigationTitle("Settings")
        .tint(RefColor.gold)
    }

    // MARK: - Event

    private var eventSection: some View {
        @Bindable var notebook = notebook

        return Section {
            LabeledContent("Event code") {
                TextField("2026cada", text: $notebook.eventCodeDraft)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($eventCodeFocused)
                    .onSubmit { notebook.applyEventCode() }
            }

            if let parsed = EventCode(notebook.eventCodeDraft) {
                // Both spellings, so it is obvious the same code works for
                // whichever source the head ref ends up using.
                LabeledContent("The Blue Alliance", value: parsed.tbaKey)
                    .font(RefFont.numeric(13))
                    .foregroundStyle(.secondary)
                LabeledContent("frc.events", value: "\(parsed.season) · \(parsed.frcEventsCode)")
                    .font(RefFont.numeric(13))
                    .foregroundStyle(.secondary)
            } else if !notebook.eventCodeDraft.isEmpty {
                Label("Not a recognisable event code", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(RefColor.goldPale)
                    .font(RefFont.text(13))
            }

            Button("Load event") { notebook.applyEventCode() }
                .disabled(EventCode(notebook.eventCodeDraft) == nil)

            NavigationLink("Recent events", value: Notebook.SettingsRoute.eventPicker)

            // Derived from whatever match is on the field, not chosen here.
            LabeledContent("Stage") {
                Text(notebook.phase.label)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Event")
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Section {
            ForEach(DataSourceKind.allCases) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { notebook.sources.isEnabled(source) },
                        set: { _ in notebook.sources.toggle(source) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).font(RefFont.text(15, .semibold))
                            Text(source.detail)
                                .font(RefFont.text(13))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let caveat = source.caveat, notebook.sources.isEnabled(source) {
                        Label(caveat, systemImage: "info.circle")
                            .font(RefFont.text(12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Turn on as many as apply. Each one knows things the others don't.")
        }
    }

    // MARK: - Coverage

    /// Capability -> the source that will answer it. This is the part that
    /// makes a multi-source setup legible instead of mysterious.
    private var coverageSection: some View {
        Section {
            ForEach(SourceCapability.allCases) { capability in
                LabeledContent {
                    if let provider = notebook.sources.provider(for: capability) {
                        Text(provider.name)
                            .font(RefFont.text(13, .medium))
                            .foregroundStyle(RefColor.goldText)
                    } else {
                        Text("No source")
                            .font(RefFont.text(13, .medium))
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capability.label).font(RefFont.text(15))
                    }
                }
            }
        } header: {
            Text("Coverage")
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        @Bindable var notebook = notebook

        return Section("Export") {
            Text(notebook.exportSummary)
                .font(RefFont.text(14))
                .foregroundStyle(.secondary)

            Button("Copy markdown") { copyToClipboard(notebook.exportMarkdown) }

            ShareLink(item: notebook.exportCSV,
                      preview: SharePreview("\(notebook.eventName) referee log")) {
                Text("Share CSV")
            }

            DisclosureGroup("Preview the report", isExpanded: $notebook.showExportPreview) {
                Text(notebook.exportMarkdown)
                    .font(RefFont.numeric(12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
#endif
