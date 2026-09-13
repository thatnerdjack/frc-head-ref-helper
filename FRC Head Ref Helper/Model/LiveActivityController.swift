//
//  LiveActivityController.swift
//  FRC Head Ref Helper
//
//  Starts, updates and ends the match Live Activity.
//
//  Updates are deliberately sparse. The countdown is carried as an end date so
//  the widget ticks itself, which means this only needs to push when the
//  CONTENT changes — a new match, a change of field state, a team picking up a
//  card. A signature of the content decides that, so a phone sitting in a
//  pocket all day is not pushing an update every second.
//

import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    private var activity: Activity<MatchActivityAttributes>?
    /// Hash of the last pushed state, so identical updates are dropped.
    private var lastSignature: Int?

    /// Whether the system will let us show one at all. The user can turn Live
    /// Activities off for the app in Settings, and we must not fight that.
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Brings the Live Activity in line with the notebook. Safe to call often.
    func sync(eventName: String, state: MatchActivityAttributes.ContentState, enabled: Bool) {
        guard enabled, isAvailable else {
            end()
            return
        }

        let signature = state.hashValue
        if let activity {
            guard signature != lastSignature else { return }
            lastSignature = signature
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            do {
                activity = try Activity.request(
                    attributes: MatchActivityAttributes(eventName: eventName),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                lastSignature = signature
            } catch {
                // Most commonly the user has Live Activities switched off, or
                // the app is in the background. Neither is worth interrupting
                // a referee over.
                activity = nil
            }
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastSignature = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
