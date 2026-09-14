//
//  TeamMediaCacheTests.swift
//  FRC Head Ref HelperTests
//
//  The cache exists so a venue network is touched as little as possible, so
//  what is worth asserting is how often it calls the loader — not that it can
//  hold bytes.
//

import Testing
import Foundation
@testable import FRC_Head_Ref_Helper

/// Counts loader calls across concurrent access.
private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private func makeCache() -> TeamMediaCache {
    // A unique directory per test: these run in parallel and a shared cache
    // directory would make them read each other's writes.
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "TeamMediaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return TeamMediaCache(directory: dir)
}

@Test("A second request for the same team does not call the loader again")
func cacheHitsAvoidTheNetwork() async {
    let cache = makeCache()
    let counter = LoadCounter()

    let first = await cache.media(for: "avatar-8341") {
        counter.bump()
        return Data([0x1, 0x2, 0x3])
    }
    let second = await cache.media(for: "avatar-8341") {
        counter.bump()
        return Data([0x9])
    }

    #expect(first == .image(Data([0x1, 0x2, 0x3])))
    #expect(second == first, "the second call served the cached bytes")
    #expect(counter.count == 1, "the loader ran once")
}

@Test("Six cells appearing at once produce one request, not six")
func concurrentRequestsShareOneLoad() async {
    // This is the case that matters: a next-match card puts six team cells on
    // screen in the same frame. Without the in-flight guard that is six
    // identical requests to a source already struggling on venue Wi-Fi.
    let cache = makeCache()
    let counter = LoadCounter()

    await withTaskGroup(of: TeamMediaResult.self) { group in
        for _ in 0..<6 {
            group.addTask {
                await cache.media(for: "avatar-4055") {
                    counter.bump()
                    try? await Task.sleep(for: .milliseconds(20))
                    return Data([0x7])
                }
            }
        }
        for await result in group {
            #expect(result == .image(Data([0x7])))
        }
    }

    #expect(counter.count == 1, "all six shared one load")
}

@Test("A team with no media is remembered as having none")
func negativeResultsAreCached() async {
    // Otherwise every row, every launch, asks again about the same team that
    // has never had an avatar.
    let cache = makeCache()
    let counter = LoadCounter()

    let first = await cache.media(for: "avatar-9999") { counter.bump(); return nil }
    let second = await cache.media(for: "avatar-9999") { counter.bump(); return nil }

    #expect(first == .none)
    #expect(second == .none)
    #expect(counter.count == 1, "absence is cached too")
}

@Test("Cached bytes survive a new cache over the same directory")
func diskCacheSurvivesRelaunch() async {
    // A relaunch at an event should already know what every team looks like.
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "TeamMediaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let first = TeamMediaCache(directory: dir)
    _ = await first.media(for: "avatar-6812") { Data([0x4, 0x5]) }

    let relaunched = TeamMediaCache(directory: dir)
    let counter = LoadCounter()
    let result = await relaunched.media(for: "avatar-6812") {
        counter.bump()
        return Data([0xFF])
    }

    #expect(result == .image(Data([0x4, 0x5])))
    #expect(counter.count == 0, "disk answered without touching the loader")
}

@Test("Different teams do not share an entry")
func keysAreDistinct() async {
    let cache = makeCache()
    _ = await cache.media(for: "avatar-1") { Data([0x1]) }
    let other = await cache.media(for: "avatar-2") { Data([0x2]) }
    #expect(other == .image(Data([0x2])))
}

@Test("A key cannot escape the cache directory")
func keysAreSanitised() async {
    // Team numbers are tame, but a key is still a filename, and a cache that
    // writes outside its own directory is a bug waiting for a strange input.
    let cache = makeCache()
    let result = await cache.media(for: "../../escape") { Data([0x1]) }
    #expect(result == .image(Data([0x1])))

    let relaunchDir = FileManager.default.temporaryDirectory
        .appending(path: "escape", directoryHint: .notDirectory)
    #expect(FileManager.default.fileExists(atPath: relaunchDir.path) == false)
}
