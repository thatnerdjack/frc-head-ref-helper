//
//  ComposeSheet.swift
//  FRC Head Ref Helper
//
//  The whole point of the app: get a call written down without looking away
//  from the field for long. Three questions in order — who, which rule, what
//  happened.
//
//  The order matters. "Who" is what you know first and are most likely to
//  forget, so it is committed before the rule search takes your attention.
//
//  Presented in a NavigationStack so Cancel/Save sit in a system Liquid Glass
//  toolbar, and the two either/or choices are system segmented Pickers.
//

#if !os(watchOS)
import SwiftUI

struct ComposeSheet: View {
    @Environment(Notebook.self) private var notebook

    private var onField: [String] { notebook.currentMatch?.onField ?? [] }

    private let threeColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private let twoColumns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 2)

    var body: some View {
        @Bindable var notebook = notebook

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    whoSection
                    ruleSection
                    severitySection

                    SectionLabel(text: "NOTE").padding(.bottom, 10)
                    // A vertical TextField gives a system prompt and growth
                    // behaviour, replacing a TextEditor plus overlaid label.
                    TextField("What you saw, what you told them",
                              text: $notebook.noteText, axis: .vertical)
                        .font(RefFont.text(15))
                        .lineLimit(3...8)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .glassCard(radius: RefRadius.card)
                        .padding(.bottom, 22)

                    if let hint = notebook.escalationHint(for: subjectForSave) {
                        // The same warning the team page shows, in front of you
                        // BEFORE the entry is committed.
                        Text(hint)
                            .font(RefFont.text(14.5))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .glassCard(.regular.tint(RefColor.gold.opacity(0.26)), radius: RefRadius.row)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(FieldBackdrop())
            .navigationTitle("New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { notebook.cancelCompose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(notebook.saveButtonTitle) { notebook.save() }
                        .buttonStyle(.glassProminent)
                        .tint(RefColor.gold)
                }
            }
        }
    }

    private var subjectForSave: String {
        notebook.composeTarget == .alliance
            ? "Alliance \(notebook.selectedAllianceSeed)"
            : notebook.activeSubject
    }

    // MARK: - Who

    private var whoSection: some View {
        @Bindable var notebook = notebook

        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "WHO", opacity: 0.72).padding(.bottom, 10)

            // Alliance-wide entries are a playoff concept. During quals there
            // are no alliances to attach one to, so the picker is not shown at
            // all rather than shown-and-disabled.
            if notebook.canLogAgainstAlliance {
                Picker("Who", selection: $notebook.composeTarget) {
                    ForEach(Notebook.ComposeTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)
            }

            if notebook.composeTarget == .team || !notebook.canLogAgainstAlliance {
                LazyVGrid(columns: threeColumns, spacing: 8) {
                    ForEach(onField, id: \.self) { number in
                        let selected = notebook.activeSubject == number
                        Button {
                            notebook.selectedSubject = number
                        } label: {
                            HStack(spacing: 8) {
                                AllianceBar(color: notebook.currentMatch?.color(of: number).bar ?? RefColor.redBar,
                                            height: 26)
                                Text(number)
                                    .font(RefFont.numeric(20, .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassCard(selected ? .regular.tint(RefColor.gold.opacity(0.32)).interactive()
                                            : .regular.interactive(),
                                   radius: RefRadius.control)
                    }
                }
                .padding(.bottom, 24)
            } else {
                LazyVGrid(columns: twoColumns, spacing: 7) {
                    ForEach(SampleEvent.alliances) { alliance in
                        let selected = notebook.selectedAllianceSeed == alliance.seed
                        Button {
                            notebook.selectedAllianceSeed = alliance.seed
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(alliance.label)
                                    .font(RefFont.text(15, .semibold))
                                    .foregroundStyle(.white)
                                Text(alliance.teamList)
                                    .font(RefFont.numeric(12.5, .medium))
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                            .padding(.horizontal, 13)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassCard(selected ? .regular.tint(RefColor.gold.opacity(0.32)).interactive()
                                            : .regular.interactive(),
                                   radius: 18)
                    }
                }
                .padding(.bottom, 10)

                Text("Playoff cards apply to the whole alliance and follow it through the bracket.")
                    .font(RefFont.text(13))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Rule

    private var ruleSection: some View {
        @Bindable var notebook = notebook

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "RULE", opacity: 0.72)
                Text(notebook.ruleCountLabel)
                    .font(RefFont.numeric(12, .medium))
                    .foregroundStyle(RefColor.goldText)
            }
            .padding(.bottom, 10)

            // Kept inline rather than using `.searchable`: this field belongs
            // to the RULE step, and hoisting it into the navigation bar would
            // break the who -> rule -> what order the sheet is built around.
            TextField("g41, pinning, frame, zone…", text: $notebook.ruleQuery)
                .font(RefFont.numeric(15, .medium))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .glassCard(radius: RefRadius.control)
                .padding(.bottom, 10)

            Picker("Category", selection: $notebook.ruleCategory) {
                ForEach(RuleCategory.allCases) { category in
                    Text(category.short).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 10)

            // Bounded so the rest of the sheet stays reachable however many
            // rules match.
            ScrollView {
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 6) {
                        ForEach(notebook.visibleRules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 300)

            if let message = notebook.noRulesMessage {
                Text(message)
                    .font(RefFont.text(14))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .glassCard(radius: RefRadius.control)
            }
        }
        .padding(.bottom, 24)
    }

    private func ruleRow(_ rule: Rule) -> some View {
        let isSelected = notebook.selectedRuleCode == rule.code
        let uses = notebook.useCount(for: rule.code)

        return Button {
            notebook.selectedRuleCode = rule.code
        } label: {
            HStack(spacing: 12) {
                Text(rule.code)
                    .font(RefFont.numeric(17, .semibold))
                    .foregroundStyle(RefColor.goldPale)
                    .frame(width: 56, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.title)
                        .font(RefFont.text(14))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(rule.violation.isEmpty ? rule.section : rule.violation)
                        .font(RefFont.text(11.5, .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // "7x" — how often this rule has come up at this event.
                if uses > 0 {
                    Text("\(uses)×")
                        .font(RefFont.numeric(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 58)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(isSelected ? .regular.tint(RefColor.gold.opacity(0.34)).interactive() : .regular.interactive(),
                   radius: RefRadius.control)
    }

    // MARK: - What happened

    private var severitySection: some View {
        @Bindable var notebook = notebook

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "WHAT HAPPENED", opacity: 0.72)
            }
            .padding(.bottom, 10)

            LazyVGrid(columns: threeColumns, spacing: 7) {
                ForEach(Severity.composable) { severity in
                    let selected = notebook.selectedSeverity == severity
                    Button {
                        notebook.selectedSeverity = severity
                    } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(severity.color)
                                .frame(width: 14, height: 14)
                            Text(severity.short)
                                .font(RefFont.text(13, .medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassCard(selected ? .regular.tint(severity.color.opacity(0.45)).interactive()
                                        : .regular.interactive(),
                               radius: 18)
                }
            }
            .padding(.bottom, 22)
        }
    }
}
#endif
