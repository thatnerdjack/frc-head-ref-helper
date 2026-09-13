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

    var body: some View {
        Group {
            #if os(watchOS)
            WatchRootView()
            #else
            RefRootView()
            #endif
        }
        .environment(notebook)
        .task {
            // Deferred to here rather than init: the model context only exists
            // once the view is in a scene.
            notebook.attach(to: modelContext)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: RefEntry.self, inMemory: true)
}
