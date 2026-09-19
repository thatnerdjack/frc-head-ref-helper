//
//  TeamAvatarStoreTests.swift
//  FRC Head Ref HelperTests
//
//  What the store promises: one fetch for the whole event, and a lookup cheap
//  enough to call from `body`.
//
//  There is nothing here asserting that images round-trip through a disk
//  directory, because there is no longer a disk directory. Robot photos are
//  URLs and belong to `URLCache`; the avatar JSON is an ordinary HTTP response
//  and also belongs to `URLCache`. Testing either would be testing Foundation.
//

import Testing
import Foundation
import SwiftUI
@testable import FRC_Head_Ref_Helper

/// Counts how many times the event's avatars were actually asked for.
private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// A 1x1 PNG. Small enough to inline, real enough for `UIImage` to decode.
private let pixelPNG = Data(base64Encoded: """
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
""")!

@Suite("Team avatar store")
@MainActor
struct TeamAvatarStoreTests {

    @Test("The event's avatars are fetched once, not once per team")
    func loadsOnce() async {
        // The whole reason this type replaced a per-team cache: frc.events
        // answers with every team at the event in a single response, so a
        // second load is a wasted request, not a cache miss.
        let calls = CallCount()
        let source = TeamAvatarSource {
            calls.bump()
            return ["254": pixelPNG, "8341": pixelPNG]
        }
        let store = TeamAvatarStore()

        await store.load(from: source)
        await store.load(from: source)

        #expect(calls.value == 1)
        #expect(store.hasLoaded)
    }

    @Test("Concurrent callers share the one load")
    func concurrentLoadsShare() async {
        // Several screens appear at once on launch and all of them want
        // avatars. There is still only one request to make.
        let calls = CallCount()
        let source = TeamAvatarSource {
            calls.bump()
            try? await Task.sleep(for: .milliseconds(50))
            return ["254": pixelPNG]
        }
        let store = TeamAvatarStore()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { @MainActor in await store.load(from: source) }
            }
        }

        #expect(calls.value == 1)
    }

    @Test("A team with an avatar resolves, one without does not")
    func lookup() async {
        let source = TeamAvatarSource { ["254": pixelPNG] }
        let store = TeamAvatarStore()
        await store.load(from: source)

        #expect(store.image(for: "254") != nil)
        // Not every team has one, and the view draws the hatched placeholder
        // rather than reserving nothing.
        #expect(store.image(for: "8341") == nil)
    }

    @Test("Bytes that are not an image are dropped, not stored empty")
    func undecodableDataIsDropped() async {
        let source = TeamAvatarSource {
            ["254": Data("not a png".utf8), "8341": pixelPNG]
        }
        let store = TeamAvatarStore()
        await store.load(from: source)

        #expect(store.image(for: "254") == nil)
        #expect(store.image(for: "8341") != nil)
    }

    @Test("An event with no avatars is not asked again")
    func emptyResultStillCounts() async {
        // The negative case the old cache tried to remember per team. Here it
        // falls out for free: the event was asked, and the answer was nothing.
        let calls = CallCount()
        let source = TeamAvatarSource {
            calls.bump()
            return [:]
        }
        let store = TeamAvatarStore()

        await store.load(from: source)
        await store.load(from: source)

        #expect(calls.value == 1)
        #expect(store.hasLoaded)
    }

    @Test("Resetting drops the event and allows a fresh load")
    func resetForgetsTheEvent() async {
        // Switching events must not leave the previous event's teams on screen.
        let calls = CallCount()
        let source = TeamAvatarSource {
            calls.bump()
            return ["254": pixelPNG]
        }
        let store = TeamAvatarStore()

        await store.load(from: source)
        #expect(store.image(for: "254") != nil)

        store.reset()
        #expect(store.image(for: "254") == nil)
        #expect(!store.hasLoaded)

        await store.load(from: source)
        #expect(calls.value == 2)
        #expect(store.image(for: "254") != nil)
    }
}
