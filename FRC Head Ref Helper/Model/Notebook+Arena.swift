//
//  Notebook+Arena.swift
//  FRC Head Ref Helper
//
//  Where the field's own account of itself lands in the model.
//
//  Until this file existed, `fieldState`, `arenaState`, `currentMatchKey` and
//  `schedule` were all sample data, and the status pill in the Now screen was a
//  button that cycled them by hand. This replaces the hand with Cheesy Arena.
//
//  One rule throughout: the field is the authority on what the field is doing.
//  Nothing here invents a state, guesses a match or interpolates a clock. When
//  the socket is not connected the app says so rather than showing the last
//  thing it heard as though it were current — `ArenaSocket.Status` is carried
//  into the model for exactly that reason.
//

import Foundation

extension Notebook {

    // MARK: - Connecting

    /// Opens the arena feed and keeps the model fed from it.
    ///
    /// Safe to call repeatedly: a second call to the same host is ignored, and
    /// a call to a different host tears the old feed down first. The referee
    /// editing the address in Settings is the normal way this happens.
    func connectToArena(host: String) {
        guard arenaHost != host || arenaClient == nil else { return }
        disconnectFromArena()

        let client = CheesyArenaClient(host: host)
        arenaClient = client
        arenaHost = host

        arenaFeed = Task { [weak self] in
            await client.start()
            // Pull the schedule once up front so "next match" works before the
            // field happens to load anything.
            await self?.refreshArenaSchedule()
            for await event in client.events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    func disconnectFromArena() {
        arenaFeed?.cancel()
        arenaFeed = nil
        let client = arenaClient
        arenaClient = nil
        arenaHost = nil
        arenaStatus = .idle
        Task { await client?.stop() }
    }

    /// Fetches the qualification schedule. Cheap to repeat — `HTTPService`
    /// returns `.unchanged` and this does nothing when the bytes have not
    /// moved, which is the normal case all day.
    func refreshArenaSchedule() async {
        guard let arenaClient else { return }
        let fetched = try? await arenaClient.schedule(.qualification)
        // `try?` wraps the client's own "nothing changed" nil, so this is a
        // double optional; both layers mean there is nothing to merge.
        guard let matches = fetched ?? nil, !matches.isEmpty else { return }
        mergeArenaSchedule(matches)
    }

    /// The connection, in words a referee can act on at the scoring table.
    var arenaStatusText: String {
        switch arenaStatus {
        case .idle:
            "Not connected"
        case .connecting(let attempt):
            attempt <= 1 ? "Connecting…" : "Connecting… (attempt \(attempt))"
        case .connected:
            "Connected"
        case .waiting(_, _, let reason):
            "Reconnecting — \(reason)"
        case .localNetworkDenied:
            // The one failure with a fix the referee can carry out themselves.
            "Local Network is off for this app — Settings › FRC Head Ref Helper"
        }
    }

    // MARK: - Applying

    /// Folds one event from the field into the model.
    func apply(_ event: ArenaEvent) {
        switch event {
        case .matchLoaded(let match):
            mergeArenaSchedule([match])
            currentMatchKey = match.key

        case .matchTime(let state, _):
            arenaState = state
            // `fieldState` is the coarse day-level state the UI paints with;
            // `arenaState` is the fine-grained one the field reports. A timeout
            // is the one place the field's view has to move the coarse one, so
            // the Now screen shows the break treatment without anybody tapping.
            fieldState = state.isTimeout ? .paused : .live
            // The socket polices silence differently during a match, and only
            // the field knows when that is.
            let running = state.isPlaying
            if let arenaClient {
                Task { await arenaClient.setMatchRunning(running) }
            }

        case .status(let status):
            arenaStatus = status
        }
    }

    /// Merges matches from the field into the schedule, keyed by play.
    ///
    /// Replaces by `MatchKey`, which includes the play number, so a replayed
    /// Q41 is added alongside the original rather than overwriting it — the
    /// whole reason `MatchKey` carries a play in the first place. Queue status
    /// and missing teams are preserved, because those come from Nexus and the
    /// arena knows nothing about them.
    func mergeArenaSchedule(_ incoming: [Match]) {
        var byKey = Dictionary(uniqueKeysWithValues: schedule.map { ($0.key, $0) })
        for var match in incoming {
            if let existing = byKey[match.key] {
                match.queueStatus = existing.queueStatus
                match.missingTeams = existing.missingTeams
                // The field reports actualStart only once it has started; do
                // not let a later load erase a start time we already saw.
                if match.actualStart == nil { match.actualStart = existing.actualStart }
            }
            byKey[match.key] = match
        }
        schedule = byKey.values.sorted { lhs, rhs in
            (lhs.scheduledStart ?? .distantFuture) < (rhs.scheduledStart ?? .distantFuture)
        }
    }
}
