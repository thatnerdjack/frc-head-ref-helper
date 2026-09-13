//
//  FRC_Head_Ref_HelperApp.swift
//  FRC Head Ref Helper
//
//  Created by Jack Doherty on 9/12/26.
//

import SwiftUI
import SwiftData

@main
struct FRC_Head_Ref_HelperApp: App {
    /// Entries are persisted on device. The store is CloudKit-compatible (see
    /// RefEntry) so the iCloud container in the entitlements can sync a
    /// referee's notebook between their phone and their watch — which is
    /// exactly the scope the design states: "Entries stay on this phone and on
    /// your watch. Nothing is sent to FMS or to the field."
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([RefEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
