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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
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
