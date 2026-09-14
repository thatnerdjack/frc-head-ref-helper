//
//  CredentialRow.swift
//  FRC Head Ref Helper
//
//  One API key in Settings.
//
//  The row has two states and no third: a key is either saved or it is not.
//  A saved key is never shown back, not even masked — the point of putting it
//  in the keychain is that the app stops being somewhere it can be read from.
//

#if !os(watchOS)
import SwiftUI

struct CredentialRow: View {
    let service: CredentialService
    let store: any CredentialStoring

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaved = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.label).font(RefFont.text(15))
                    Text(service.source)
                        .font(RefFont.text(12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isEditing {
                    Button("Cancel") { stopEditing() }
                        .font(RefFont.text(14))
                } else {
                    Text(isSaved ? "Saved" : "Not set")
                        .font(RefFont.numeric(13, .medium))
                        .foregroundStyle(isSaved ? RefColor.goldPale : .secondary)
                    Button(isSaved ? "Replace" : "Add") { startEditing() }
                        .font(RefFont.text(14))
                }
            }

            if isEditing {
                // SecureField, not TextField: this is typed in a pit with
                // people around.
                SecureField(service.hint, text: $draft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)

                HStack {
                    Button("Save", action: save)
                        .buttonStyle(.glassProminent)
                        .tint(RefColor.gold)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isSaved {
                        Button("Clear", role: .destructive) { write(nil) }
                            .buttonStyle(.glass)
                    }
                }
                .controlSize(.small)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(RefFont.text(12))
                    .foregroundStyle(RefColor.goldPale)
            }
        }
        .task { refresh() }
    }

    // MARK: - Actions

    private func refresh() {
        isSaved = store.hasToken(for: service)
    }

    private func startEditing() {
        draft = ""
        failure = nil
        isEditing = true
    }

    private func stopEditing() {
        draft = ""
        isEditing = false
    }

    private func save() {
        write(draft)
    }

    /// Nil clears. The store treats an empty string the same way, so there is
    /// no path that leaves an empty item reading as "Saved".
    private func write(_ token: String?) {
        do {
            try store.setToken(token, for: service)
            failure = nil
            stopEditing()
            refresh()
        } catch {
            // Surfaced rather than swallowed: a key that silently failed to
            // save looks identical to one that saved, right up until the event.
            failure = "\(error)"
        }
    }
}
#endif
