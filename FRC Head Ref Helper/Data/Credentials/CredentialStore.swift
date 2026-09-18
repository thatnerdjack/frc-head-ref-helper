//
//  CredentialStore.swift
//  FRC Head Ref Helper
//
//  Credentials for the four authenticated sources.
//
//  Three take a key in a header; Cheesy Arena takes an admin password at
//  POST /login and answers with a session cookie.
//
//  Nothing here ever logs a token. The UI shows a stored value through a
//  `SecureField`, so it is masked on screen the same way Settings masks a
//  Wi-Fi password — enough for a phone held in a pit, without a bespoke
//  never-redisplay control to maintain.
//

import Foundation
import Security

// MARK: - Services

/// The authenticated sources, and how each one proves who it is.
nonisolated enum CredentialService: String, CaseIterable, Sendable, Identifiable {
    /// Sent as HTTP Basic, so the stored value is the whole "username:token"
    /// pair FIRST hands out rather than a bare token.
    case frcEvents
    /// Sent as the `X-TBA-Auth-Key` header.
    case blueAlliance
    /// Sent as the `Nexus-Api-Key` header.
    case frcNexus
    /// The arena's admin password.
    ///
    /// Unlike the other three this is not a header. Cheesy Arena authenticates
    /// the `admin` user at `POST /login` and hands back a `session_token`
    /// cookie, which URLSession then carries automatically. Storing it here
    /// keeps every secret in one place rather than leaving this one in a
    /// settings field.
    case cheesyArena

    var id: String { rawValue }

    var label: String {
        switch self {
        case .frcEvents: "frc.events"
        case .blueAlliance: "The Blue Alliance"
        case .frcNexus: "FRC Nexus"
        case .cheesyArena: "Cheesy Arena"
        }
    }

    /// What to type, in the words the source's own site uses.
    var hint: String {
        switch self {
        case .frcEvents: "username:token"
        case .blueAlliance: "Read API key"
        case .frcNexus: "API key"
        case .cheesyArena: "Admin password"
        }
    }

    /// Keychain service string. Namespaced by bundle id so a second app on the
    /// same device can never collide with these.
    var keychainService: String {
        "me.jackdoherty.FRC-Head-Ref-Helper.\(rawValue)"
    }
}

// MARK: - The protocol

nonisolated protocol CredentialStoring: Sendable {
    func token(for service: CredentialService) throws -> String?
    func setToken(_ token: String?, for service: CredentialService) throws
}

extension CredentialStoring {
    func hasToken(for service: CredentialService) -> Bool {
        ((try? token(for: service)) ?? nil)?.isEmpty == false
    }
}

// MARK: - Errors

nonisolated enum CredentialError: Error, Equatable, CustomStringConvertible {
    case keychain(OSStatus)
    case notUTF8

    var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(message.map { ": \($0)" } ?? "")"
        case .notUTF8:
            return "Stored credential was not valid UTF-8"
        }
    }
}

// MARK: - Keychain

/// The real store.
///
/// Items are `kSecAttrSynchronizable`, so a key entered on the phone appears on
/// the iPad and the second phone signed into the same Apple Account. A head
/// referee sets these up once, and iCloud Keychain is end-to-end encrypted, so
/// the alternative — retyping a long token on every device, in a pit, before an
/// event — buys nothing.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than `WhenUnlocked` because the
/// app needs to reach frc.events from a background refresh with the phone in a
/// pocket, which is the normal state of a phone at an event. The
/// `ThisDeviceOnly` variants are deliberately not used — they are incompatible
/// with synchronizable items.
nonisolated struct KeychainCredentialStore: CredentialStoring {

    init() {}

    func token(for service: CredentialService) throws -> String? {
        var query = Self.baseQuery(for: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            guard let token = String(data: data, encoding: .utf8) else {
                throw CredentialError.notUTF8
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialError.keychain(status)
        }
    }

    func setToken(_ token: String?, for service: CredentialService) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clearing and storing-an-empty-string are the same intent. Treating
        // them differently would leave an empty item that reads as "Saved".
        guard let trimmed, !trimmed.isEmpty else {
            let status = SecItemDelete(Self.baseQuery(for: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychain(status)
            }
            return
        }

        guard let data = trimmed.data(using: .utf8) else { throw CredentialError.notUTF8 }

        // Update first, add if absent. SecItemAdd on an existing item fails
        // with errSecDuplicateItem rather than overwriting.
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(Self.baseQuery(for: service) as CFDictionary,
                                         update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialError.keychain(updateStatus)
        }

        var insert = Self.baseQuery(for: service)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
    }

    private static func baseQuery(for service: CredentialService) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.keychainService,
            kSecAttrAccount as String: service.rawValue,
            // Must be on the query as well as the insert. A search that omits
            // this defaults to non-synchronizable items only and would never
            // find the key this device just synced down.
            kSecAttrSynchronizable as String: true,
        ]
    }
}

// MARK: - In-memory

/// The store the tests use.
///
/// Not a convenience: Keychain access from a simulator test bundle depends on
/// entitlements the test host may not carry, and it fails in ways that have
/// nothing to do with the code under test. Anything asserting on credential
/// BEHAVIOUR should use this; `KeychainCredentialStore` is exercised by hand on
/// a device.
nonisolated final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [CredentialService: String] = [:]

    init(seed: [CredentialService: String] = [:]) {
        tokens = seed
    }

    func token(for service: CredentialService) throws -> String? {
        lock.withLock { tokens[service] }
    }

    func setToken(_ token: String?, for service: CredentialService) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if let trimmed, !trimmed.isEmpty {
                tokens[service] = trimmed
            } else {
                tokens.removeValue(forKey: service)
            }
        }
    }
}
