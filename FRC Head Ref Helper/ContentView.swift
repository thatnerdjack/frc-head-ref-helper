//
//  ContentView.swift
//  FRC Head Ref Helper
//
//  Picks the right shell for the device and hands both of them the same
//  Notebook. The phone gets the full notebook; the watch gets the read-only
//  glance view.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    /// One Notebook for the whole app. It owns the loaded entries plus all the
    /// UI state, so every screen reads the same badges and hints.
    @State private var notebook = Notebook()

    /// One avatar store for the whole app. frc.events returns every team at the
    /// event in a single response, so this is loaded once here rather than
    /// per row or per screen.
    @State private var avatars = TeamAvatarStore()

    @Environment(\.teamAvatarSource) private var avatarSource

    var body: some View {
        Group {
            #if os(watchOS)
            WatchRootView()
            #else
            RefRootView()
            #endif
        }
        .environment(notebook)
        .environment(avatars)
        .task {
            // Deferred to here rather than init: the model context only exists
            // once the view is in a scene.
            notebook.attach(to: modelContext)
        }
        .task(id: notebook.eventCode) {
            // A different event is a different set of teams, so the old
            // event's avatars are not merely stale, they are wrong.
            avatars.reset()
            await avatars.load(from: avatarSource)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: RefEntry.self, inMemory: true)
}
