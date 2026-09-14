//
//  TeamMediaCache.swift
//  FRC Head Ref Helper
//
//  Team avatars and robot photos, cached to disk.
//
//  Not `AsyncImage`. That re-fetches every time a row scrolls back into view,
//  which on a venue network — shared with a few thousand phones and whatever
//  the field is doing — is the difference between a list that scrolls and one
//  that stutters. An avatar for a given team and season never changes, so it
//  should be fetched once for the whole event and then never again.
//
//  Two layers, on purpose. The memory layer keeps a scrolling list smooth; the
//  disk layer means the app relaunches at an event already knowing what every
//  team looks like, without touching the network at all.
//
//  NOTHING HERE FETCHES YET. The loader is supplied by the caller, and no
//  caller supplies a real one until the source clients land. That keeps this
//  independently mergeable and means wiring up frc.events avatars later is a
//  small change rather than a rewrite.
//

import Foundation

/// Where a cached image came from, so callers can tell "we have nothing" from
/// "we looked and there genuinely isn't one".
nonisolated enum TeamMediaResult: Sendable, Equatable {
    case image(Data)
    /// The source was asked and said this team has no media. Cached as a
    /// negative so the app does not ask again for every row, every launch.
    case none
}

actor TeamMediaCache {

    /// Shared because the cache is only useful if every screen hits the same
    /// one — the point is that the second screen to want 8341's avatar does
    /// not fetch it again.
    static let shared = TeamMediaCache()

    private var memory: [String: TeamMediaResult] = [:]
    private var inFlight: [String: Task<TeamMediaResult, Never>] = [:]
    private let directory: URL?

    init(directory: URL? = TeamMediaCache.defaultDirectory()) {
        self.directory = directory
    }

    /// `Library/Caches` rather than Application Support: this is all
    /// re-downloadable, so the system is welcome to reclaim it under pressure.
    private static func defaultDirectory() -> URL? {
        guard let base = try? FileManager.default.url(for: .cachesDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let dir = base.appending(path: "TeamMedia", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns cached media, or runs `load` once and caches whatever it says.
    ///
    /// Concurrent callers for the same key share one `load`. Six team cells
    /// appearing at once must not become six identical requests — that is the
    /// stampede this exists to prevent.
    func media(for key: String,
               load: @Sendable @escaping () async -> Data?) async -> TeamMediaResult {
        if let hit = memory[key] { return hit }

        if let data = readFromDisk(key) {
            let result = TeamMediaResult.image(data)
            memory[key] = result
            return result
        }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<TeamMediaResult, Never> {
            let data = await load()
            return data.map(TeamMediaResult.image) ?? .none
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        memory[key] = result
        if case .image(let data) = result { writeToDisk(key, data) }
        return result
    }

    /// What is already known, without asking anyone. Lets a view render a
    /// cached avatar on first paint instead of flashing a placeholder.
    func cached(_ key: String) -> TeamMediaResult? {
        if let hit = memory[key] { return hit }
        guard let data = readFromDisk(key) else { return nil }
        let result = TeamMediaResult.image(data)
        memory[key] = result
        return result
    }

    func clear() {
        memory.removeAll()
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Disk

    private func fileURL(_ key: String) -> URL? {
        guard let directory else { return nil }
        // Keys are team numbers and season codes, but a hostile or merely
        // surprising key must never escape the cache directory.
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        guard !safe.isEmpty else { return nil }
        return directory.appending(path: safe, directoryHint: .notDirectory)
    }

    private func readFromDisk(_ key: String) -> Data? {
        guard let url = fileURL(key) else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    private func writeToDisk(_ key: String, _ data: Data) {
        guard let url = fileURL(key) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
