//
//  ArenaScreen.swift
//  FRC Head Ref Helper
//
//  Offseason events run Cheesy Arena locally instead of FMS, so the app needs
//  somewhere to be pointed at it.
//
//  The design is explicit that this is optional: the app keeps working from
//  its last schedule when the arena is unreachable, and entries never depend
//  on it. A referee's notebook must not stop working because a field laptop
//  rebooted.
//

#if !os(watchOS)
import SwiftUI

struct ArenaScreen: View {
    @Environment(Notebook.self) private var notebook

    /// Injectable so a preview or test can hand in the in-memory store —
    /// Keychain access from a test bundle is entitlement-flaky.
    var credentialStore: any CredentialStoring = KeychainCredentialStore()

    var body: some View {
        @Bindable var notebook = notebook

        Form {
            Section("Server address") {
                HStack {
                    TextField("10.0.100.5", text: $notebook.sources.arenaAddress)
                        .font(RefFont.numeric(20, .medium))
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        #endif
                    Text(":8080")
                        .font(RefFont.numeric(14, .medium))
                        .foregroundStyle(.secondary)
                }

                // The arena's admin password lives here rather than with the web
                // API keys. It is not an API key: Cheesy Arena authenticates
                // the `admin` user at POST /login and answers with a session
                // cookie. More to the point, this is the screen a referee opens
                // to reach the field, so this is where they look for it.
                SecureField("Admin password", text: arenaPassword)
                    .textContentType(.password)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                Button("Connect") {
                    // Switch the match source across; the socket client itself
                    // is still to be written.
                    // Enabling is additive: connecting the field server does
                    // not switch anything else off.
                    notebook.sources.enabled.insert(.cheesyArena)
                    notebook.settingsPath.removeAll()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(RefColor.gold)
                .frame(maxWidth: .infinity)
            }

            Section {
                ForEach(SampleEvent.recentServers) { server in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.address).font(RefFont.numeric(15, .semibold))
                            Text(server.detail)
                                .font(RefFont.text(13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        StatusBadge(
                            text: server.isReachable ? "REACHABLE" : "OFFLINE",
                            background: server.isReachable ? RefColor.live : Color.white.opacity(0.16),
                            foreground: server.isReachable ? RefColor.liveInk : .white.opacity(0.9)
                        )
                    }
                }
            } header: {
                Text("Recent servers")
            } footer: {
                Text("When the arena is unreachable the app keeps working from its last schedule.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(FieldBackdrop())
        .navigationTitle("Cheesy Arena")
        .navigationBarTitleDisplayMode(.inline)
    }
    /// Reads and writes the keychain directly. Written on every edit rather
    /// than on submit, so a referee who types it and taps Connect without
    /// dismissing the keyboard does not lose it.
    private var arenaPassword: Binding<String> {
        Binding(
            get: { (try? credentialStore.token(for: .cheesyArena)) ?? "" },
            set: { try? credentialStore.setToken($0, for: .cheesyArena) }
        )
    }
}
#endif
