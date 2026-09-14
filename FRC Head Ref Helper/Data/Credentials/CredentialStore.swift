//
//  CredentialStore.swift
//  FRC Head Ref Helper
//
//  API keys for the three authenticated sources.
//
//  Cheesy Arena is deliberately absent: it is an unauthenticated server on the
//  local field network, and giving it a credential slot would imply otherwise.
//
//  Nothing here ever logs a token, and the UI never redisplays one — a stored
//  key reads as "Saved" and nothing more. A head referee may well be using a
//  key that belongs to the whole team, and a screen that will happily show it
//  back is a screen that leaks it to whoever is looking over their shoulder in
//  the pits.
//

import Foundation
import Security

// MARK: - Services

/// The authenticated sources, and how each one carries its key.
nonisolated enum CredentialService: String, CaseIterable, Sendable, Identifiable {
    /// Sent as HTTP Basic, so the stored value is the whole "username:token"
    /// pair FIRST hands out rather than a bare token.
    case frcEvents
    /// Sent as the `X-TBA-Auth-Key` header.
    case blueAlliance
    /// Sent as the `Nexus-Api-Key` header.
    case frcNexus

    var id: String { rawValue }

    var label: String {
        switch self {
        case .frcEvents: "frc.events"
        case .blueAlliance: "The Blue Alliance"
        case .frcNexus: "FRC Nexus"
        }
    }

    /// What to type, in the words the source's own site uses.
    var hint: String {
        switch self {
        case .frcEvents: "username:token"
        case .blueAlliance: "Read API key"
        case .frcNexus: "API key"
        }
    }

    /// Where to get one. Shown as text rather than a link: a referee setting
    /// this up is on a laptop, not tapping through on the phone mid-event.
    var source: String {
        switch self {
        case .frcEvents: "frc-events.firstinspires.org/services/API"
        case .blueAlliance: "thebluealliance.com/account"
        case .frcNexus: "frc.nexus"
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
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is two decisions:
///
/// *After first unlock* rather than *when unlocked*, because the app needs to
/// reach frc.events from a background refresh with the phone in a pocket, which
/// is the normal state of a phone at an event.
///
/// *This device only* — not `kSecAttrSynchronizable` — because these keys are
/// frequently a team's shared credentials rather than a personal one. Syncing a
/// shared key onto every device signed into the same Apple Account is a worse
/// outcome than typing it twice. If that trade ever wants revisiting it is a
/// one-line change here, and a deliberate one.
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
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
    }

    private static func baseQuery(for service: CredentialService) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.keychainService,
            kSecAttrAccount as String: service.rawValue,
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
