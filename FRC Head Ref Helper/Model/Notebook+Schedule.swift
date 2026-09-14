//
//  Notebook+Schedule.swift
//  FRC Head Ref Helper
//
//  Reading the match schedule: which match is on the field, which one is up
//  next, how far behind the day is running — and the one mutation the field
//  can force on us, an ARENA FAULT replay.
//

import Foundation

extension Notebook {

    // MARK: - Schedule

    /// Read off the field rather than set in Settings: whatever match is on
    /// now (or up next) says which stage the event is in.
    var phase: EventPhase {
        EventPhase(matchLevel: (currentMatch ?? nextMatch)?.key.level)
    }

    var currentMatch: Match? {
        guard let currentMatchKey else { return nil }
        return schedule.first { $0.key == currentMatchKey }
    }

    /// The next match to be played. Explicitly NOT "the one after the current
    /// index": matches run out of order often enough that the next one is
    /// whichever unplayed match is scheduled soonest.
    var nextMatch: Match? {
        schedule
            .filter { $0.queueStatus != .played && $0.key != currentMatchKey }
            .min { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }
    }

    /// The schedule ordered by what actually happened: matches that have run,
    /// in the order they ran, then everything still to come by schedule.
    var matchesInPlayOrder: [Match] {
        let played = schedule.filter { $0.actualStart != nil }
            .sorted { ($0.actualStart ?? .distantPast) < ($1.actualStart ?? .distantPast) }
        let upcoming = schedule.filter { $0.actualStart == nil }
            .sorted { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }
        return played + upcoming
    }

    /// How far behind the schedule the event is running, from the most recent
    /// match that has both a scheduled and an actual start.
    var minutesBehindSchedule: Int? {
        matchesInPlayOrder.reversed().first { $0.minutesBehindSchedule != nil }?.minutesBehindSchedule
    }

    /// Records that the field is replaying a match after an ARENA FAULT.
    ///
    /// This is an INGEST operation, not a user action: FMS decides when a
    /// replay happens, it can happen to any match, and it can happen at any
    /// time. The schedule source calls this; there is deliberately no button
    /// for it. The original play keeps its entries, and the replay becomes a
    /// new play of the same match number.
    func recordReplay(of key: MatchKey) {
        // Only the LATEST play of a match number can be replayed. The original
        // play stays in the schedule on purpose — it keeps its entries — so
        // "find this key and insert play + 1" fires again on a duplicate
        // notification and produces a second play 2 with the same id. The
        // field sends duplicate frames as a matter of course, so this guard is
        // load-bearing rather than defensive.
        let plays = schedule.filter { $0.key.level == key.level && $0.key.number == key.number }
        guard let latest = plays.max(by: { $0.key.play < $1.key.play }),
              latest.key.play == key.play,
              let index = schedule.firstIndex(where: { $0.key == latest.key })
        else { return }
        let match = schedule[index]

        var original = match
        original.queueStatus = .played
        schedule[index] = original

        var replay = Match(key: MatchKey(level: match.key.level,
                                         number: match.key.number,
                                         play: match.key.play + 1),
                           red: match.red, blue: match.blue,
                           scheduledStart: now,
                           actualStart: nil,
                           queueStatus: .onDeck)
        replay.missingTeams = []
        schedule.insert(replay, at: index + 1)
        currentMatchKey = replay.key
        show(toast: "\(match.key.short) is being replayed. Entries from the earlier play are kept.")
    }
}
