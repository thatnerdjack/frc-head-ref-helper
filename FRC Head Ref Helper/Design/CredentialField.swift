//
//  CredentialField.swift
//  FRC Head Ref Helper
//
//  A masked field backed by the keychain.
//
//  Deliberately NOT a read-through `Binding`, which is how this started out:
//
//      Binding(get: { try? store.token(for: service) },
//              set: { try? store.setToken($0, for: service) })
//
//  That reads well and behaves badly, in three separate ways.
//
//  A binding's getter runs inside `body`, so every render pass became a
//  synchronous `SecItemCopyMatching` on the main thread — and because these
//  items are `kSecAttrSynchronizable`, that is an XPC round trip to securityd
//  rather than a dictionary lookup. Three fields on the Settings screen meant
//  three of them per pass.
//
//  The setter ran on every keystroke, so a forty-character Blue Alliance key
//  was forty keychain writes, each one queueing an iCloud Keychain sync.
//
//  Worst of the three: `try?` threw the failure away, and since the getter
//  read straight back through to the keychain, a write that quietly failed
//  made the text vanish from under the referee's fingers as they typed, with
//  nothing on screen to explain it.
//
//  So: read once, write on commit, and say so when a write fails.
//

#if !os(watchOS)
import SwiftUI

/// A `SecureField` whose value lives in the keychain.
///
/// The value is loaded once when the field appears and written back when the
/// referee is finished with it — on return, on losing focus, or on leaving the
/// screen. Committing on focus loss is the important one: somebody who types a
/// key and immediately taps Connect without dismissing the keyboard has
/// finished editing, whatever the keyboard thinks.
struct CredentialField: View {
    let service: CredentialService
    let store: any CredentialStoring
    /// Placeholder text. Defaults to the service's own wording for what to
    /// type, which is the wording that source's website uses.
    var prompt: String?

    @State private var text = ""
    @State private var failure: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            SecureField(prompt ?? service.hint, text: $text)
                .focused($isFocused)
                .textContentType(.password)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            // Only ever present when a write actually failed, so the row keeps
            // its normal height in the ordinary case.
            if let failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
        }
        // `.task` rather than `.onAppear` so this is off the render path
        // entirely, and re-runs if the field is ever reused for another
        // service.
        .task(id: service) {
            text = (try? store.token(for: service)) ?? ""
            failure = nil
        }
        .onSubmit(save)
        .onChange(of: isFocused) { _, focused in
            if !focused { save() }
        }
        .onDisappear(perform: save)
    }

    private func save() {
        do {
            try store.setToken(text, for: service)
            failure = nil
        } catch {
            // Shown, not swallowed. A key that did not save is the difference
            // between an app that pulls the schedule at 7am and one that does
            // not, and the referee can only fix what they can see.
            failure = String(describing: error)
        }
    }
}
#endif
