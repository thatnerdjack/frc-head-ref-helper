//
//  CredentialStoreTests.swift
//  FRC Head Ref HelperTests
//
//  Asserted against the in-memory store rather than the keychain: Keychain
//  access from a simulator test bundle depends on entitlements the test host
//  may not carry, and it fails in ways that have nothing to do with the code
//  under test. The behaviour being pinned here — what counts as "set", what
//  clearing means — is shared by both implementations.
//

import Testing
import Foundation
@testable import FRC_Head_Ref_Helper

@Test("A service with no key reads as absent, not empty")
func absentTokenIsNil() throws {
    let store = InMemoryCredentialStore()
    for service in CredentialService.allCases {
        #expect(try store.token(for: service) == nil)
        #expect(store.hasToken(for: service) == false)
    }
}

@Test("A saved key round-trips")
func tokenRoundTrips() throws {
    let store = InMemoryCredentialStore()
    try store.setToken("abc123", for: .blueAlliance)
    #expect(try store.token(for: .blueAlliance) == "abc123")
    #expect(store.hasToken(for: .blueAlliance))
}

@Test("Services do not share storage")
func servicesAreIndependent() throws {
    let store = InMemoryCredentialStore()
    try store.setToken("tba", for: .blueAlliance)
    #expect(try store.token(for: .frcEvents) == nil)
    #expect(try store.token(for: .frcNexus) == nil)
}

@Test("Clearing a key removes it rather than blanking it")
func clearingRemoves() throws {
    let store = InMemoryCredentialStore(seed: [.frcNexus: "key"])
    try store.setToken(nil, for: .frcNexus)
    #expect(try store.token(for: .frcNexus) == nil)
    #expect(store.hasToken(for: .frcNexus) == false)
}

@Test("Whitespace-only input clears rather than storing a key that is not one")
func whitespaceIsNotAKey() throws {
    // Otherwise the row reads "Saved" and every request fails authentication
    // at the event, which is the worst possible time to discover it.
    let store = InMemoryCredentialStore(seed: [.frcEvents: "user:token"])
    try store.setToken("   ", for: .frcEvents)
    #expect(store.hasToken(for: .frcEvents) == false)
}

@Test("A key is trimmed, because pasting one brings whitespace with it")
func tokensAreTrimmed() throws {
    let store = InMemoryCredentialStore()
    try store.setToken("  user:token\n", for: .frcEvents)
    #expect(try store.token(for: .frcEvents) == "user:token")
}

@Test("Every service has a distinct keychain service string")
func keychainServiceStringsAreDistinct() {
    // A collision here would silently overwrite one source's key with
    // another's, and both rows would still read "Saved".
    let names = CredentialService.allCases.map(\.keychainService)
    #expect(Set(names).count == names.count)
    #expect(names.allSatisfy { $0.hasPrefix("me.jackdoherty.FRC-Head-Ref-Helper.") })
}

@Test("The API keys section covers the header-key services and not the arena")
func webAPIKeysExcludeTheArena() {
    // The arena's password is entered on its own connection screen, next to
    // the address. Listing it here as well would put one credential in two
    // places.
    #expect(CredentialService.webAPIKeys.contains(.cheesyArena) == false)
    #expect(Set(CredentialService.webAPIKeys) == [.frcEvents, .blueAlliance, .frcNexus])
}

@Test("Every source the app authenticates against has a slot")
func everySourceHasASlot() {
    // Cheesy Arena included: it authenticates the `admin` user at POST /login
    // and answers with a session cookie, so its password is a credential like
    // any other rather than a settings field.
    #expect(Set(CredentialService.allCases.map(\.rawValue))
            == ["frcEvents", "blueAlliance", "frcNexus", "cheesyArena"])
}
