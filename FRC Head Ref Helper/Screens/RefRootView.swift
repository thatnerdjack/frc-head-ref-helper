//
//  RefRootView.swift
//  FRC Head Ref Helper
//
//  The phone shell. A system TabView supplies the Liquid Glass tab bar, and a
//  NavigationStack per tab supplies the glass toolbars and back behaviour, so
//  neither is hand-built here.
//
//  The design drew a detached tab pill with a separate round "+" beside it.
//  The system equivalents are the Liquid Glass tab bar and
//  `.tabViewBottomAccessory`, which is the platform's own "control floating
//  above the tab bar" slot, so compose lives there.
//

#if !os(watchOS)
import SwiftUI

struct RefRootView: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        @Bindable var notebook = notebook

        TabView(selection: $notebook.selectedTab) {
            Tab("Now", systemImage: "flag.checkered", value: Notebook.MainTab.now) {
                NavigationStack(path: $notebook.nowPath) {
                    currentFieldScreen
                        .navigationDestination(for: String.self) { subject in
                            TeamDetailScreen(subject: subject)
                        }
                }
                .refToast()
            }

            Tab("Teams", systemImage: "person.3", value: Notebook.MainTab.teams) {
                NavigationStack(path: $notebook.teamsPath) {
                    TeamsScreen()
                        .navigationDestination(for: String.self) { subject in
                            TeamDetailScreen(subject: subject)
                        }
                }
                .refToast()
            }

            Tab("Settings", systemImage: "gearshape", value: Notebook.MainTab.settings) {
                NavigationStack(path: $notebook.settingsPath) {
                    SettingsScreen()
                        .navigationDestination(for: Notebook.SettingsRoute.self) { route in
                            switch route {
                            case .eventPicker: EventPickerScreen()
                            case .arena: ArenaScreen()
                            }
                        }
                }
                .refToast()
            }
        }
        .tabViewBottomAccessory {
            ComposeAccessory()
        }
        .sheet(isPresented: $notebook.isComposing) {
            ComposeSheet()
        }
        .preferredColorScheme(.dark)
        .tint(RefColor.gold)
    }

    /// End of day replaces the Now screen rather than living beside it — there
    /// is no "now" once the field is closed.
    @ViewBuilder
    private var currentFieldScreen: some View {
        if notebook.fieldState == .dayComplete {
            DayCompleteScreen()
        } else {
            NowScreen()
        }
    }
}

// MARK: - Toast presentation

private struct ToastOverlay: ViewModifier {
    @Environment(Notebook.self) private var notebook

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = notebook.toast {
                    ToastBanner(message: toast)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: notebook.toast)
    }
}

extension View {
    /// Shows the save confirmation / escalation warning above the tab bar.
    func refToast() -> some View { modifier(ToastOverlay()) }
}

// MARK: - Compose accessory

/// Sits in the tab bar's accessory slot. The system draws its glass; this only
/// supplies the label and the action.
struct ComposeAccessory: View {
    @Environment(Notebook.self) private var notebook

    var body: some View {
        Button {
            notebook.startCompose()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(RefColor.gold)
                Text("New entry")
                    .font(RefFont.text(15, .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(notebook.currentMatch?.key.short ?? "—")
                    .font(RefFont.numeric(13, .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New entry")
    }
}

// MARK: - Toast

/// Confirmation after a save — or, when saving just tripped the escalation
/// rule, the warning instead. Same slot either way.
struct ToastBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(RefFont.text(14.5))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .glassCard(.regular.tint(RefColor.gold.opacity(0.25)), radius: 26)
    }
}
#endif
