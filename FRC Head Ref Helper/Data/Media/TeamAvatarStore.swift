//
//  TeamAvatarStore.swift
//  FRC Head Ref Helper
//
//  Every team's avatar at this event, fetched once.
//
//  This replaces a general-purpose two-tier media cache, and the reason is the
//  shape of the upstream API rather than anything about caching.
//
//  frc.events does not serve avatars per team. `/v3/{season}/avatars` takes an
//  event code and answers with EVERY team at that event in one response, each
//  avatar base64-encoded inside the JSON. There is no per-team request, which
//  means there is no request stampede to deduplicate and no per-team key to
//  cache — the whole event arrives at once or not at all.
//
//  It also means there is nothing for a bespoke disk cache to do. The response
//  is an ordinary HTTP GET through `HTTPService`, whose `URLCache` already
//  stores it on disk and revalidates it. A second copy of the same bytes, in a
//  directory we evict by hand, is the weaker half of a thing URLSession is
//  already doing.
//
//  What IS needed is the decoded result held in memory, so a list does not
//  re-decode forty PNGs every time it scrolls. That is this type, and it is a
//  plain dictionary rather than an `NSCache` on purpose: the contents are
//  bounded by the number of teams at one event — forty-ish small images — and
//  a cache that evicts entries we are certain to ask for again buys nothing.
//
//  NOTHING HERE FETCHES YET. `TeamAvatarSource` is supplied by the caller and
//  no caller supplies a real one until the frc.events client lands.
//

import SwiftUI

// MARK: - Source

/// Supplies every avatar at the current event, keyed by team number.
///
/// One closure, one call, the whole event — deliberately mirroring what
/// frc.events actually returns rather than inventing a per-team accessor that
/// would have to be assembled from the same single response anyway.
nonisolated struct TeamAvatarSource: Sendable {
    let allAvatars: @Sendable () async -> [String: Data]

    static let none = TeamAvatarSource { [:] }
}

private struct TeamAvatarSourceKey: EnvironmentKey {
    static let defaultValue = TeamAvatarSource.none
}

extension EnvironmentValues {
    var teamAvatarSource: TeamAvatarSource {
        get { self[TeamAvatarSourceKey.self] }
        set { self[TeamAvatarSourceKey.self] = newValue }
    }
}

// MARK: - Store

/// Holds the event's avatars, decoded and ready to draw.
///
/// `@MainActor` because every reader is a view: `image(for:)` is called during
/// `body`, and a dictionary lookup on the main actor is the cheapest possible
/// thing to do there. Decoding happens once, off the render path, in `load`.
@MainActor
@Observable
final class TeamAvatarStore {

    /// Decoded and ready. Bounded by the event's team count.
    private var images: [String: Image] = [:]

    /// Whether a load has completed, successfully or not. A source that
    /// genuinely has no avatars must not be asked again on every row.
    private(set) var hasLoaded = false

    private var loading: Task<Void, Never>?

    init() {}

    /// What is already known, without asking anyone.
    ///
    /// Safe to call from `body` — it is a dictionary read and nothing else.
    func image(for team: String) -> Image? { images[team] }

    /// Fetches the event's avatars once.
    ///
    /// Concurrent callers share the one load: several screens appear at once on
    /// launch and all of them want avatars, but there is only ever one request
    /// to make.
    func load(from source: TeamAvatarSource) async {
        if hasLoaded { return }
        if let loading {
            await loading.value
            return
        }

        let task = Task { [weak self] in
            let raw = await source.allAvatars()
            // Decoding is the expensive half, so it happens here — once for the
            // whole event — rather than per row on first paint.
            let decoded = await Self.decode(raw)
            guard let self else { return }
            self.images = decoded
            self.hasLoaded = true
        }
        loading = task
        await task.value
        loading = nil
    }

    /// Forgets the event's avatars. Called when the event changes: the next
    /// event's teams are a different set entirely.
    func reset() {
        loading?.cancel()
        loading = nil
        images = [:]
        hasLoaded = false
    }

    /// Off the main actor — decoding forty PNGs is real work and does not
    /// belong on the thread drawing the match clock.
    private nonisolated static func decode(_ raw: [String: Data]) async -> [String: Image] {
        #if canImport(UIKit)
        return raw.compactMapValues { data in
            UIImage(data: data).map(Image.init(uiImage:))
        }
        #else
        return [:]
        #endif
    }
}
