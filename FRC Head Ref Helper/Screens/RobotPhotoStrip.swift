//
//  RobotPhotoStrip.swift
//  FRC Head Ref Helper
//
//  Robot photos on a team's page.
//
//  Worth the space because "which one was that?" is a real question. A head
//  referee watching six robots gets a call about one of them, and the team
//  number on the bumper is not always the thing they saw — the mechanism was.
//  A photo closes that gap faster than a number does.
//
//  Renders NOTHING when a team has no photos, rather than an empty frame or a
//  "no photos" apology. A team page is read between matches with seconds to
//  spare, and blank space that says nothing is worse than no space at all.
//
//  NOTHING HERE FETCHES YET. The loader comes from the environment and no one
//  supplies a real one until The Blue Alliance client lands.
//

#if !os(watchOS)
import SwiftUI

/// Supplies robot photo bytes for a team. Nil today.
nonisolated struct RobotPhotoLoader: Sendable {
    /// Ordered newest first — this season's robot is the one being asked about.
    let photos: @Sendable (_ team: String) async -> [Data]

    static let none = RobotPhotoLoader { _ in [] }
}

private struct RobotPhotoLoaderKey: EnvironmentKey {
    static let defaultValue = RobotPhotoLoader.none
}

extension EnvironmentValues {
    var robotPhotoLoader: RobotPhotoLoader {
        get { self[RobotPhotoLoaderKey.self] }
        set { self[RobotPhotoLoaderKey.self] = newValue }
    }
}

struct RobotPhotoStrip: View {
    let team: String

    @Environment(\.robotPhotoLoader) private var loader
    @State private var images: [Image] = []

    private let height: CGFloat = 132

    var body: some View {
        // An alliance page has no robot, and a team with no photos gets no
        // strip. Both collapse to nothing at all.
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "ROBOT")

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            image
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: height * 1.4, height: height)
                                .clipShape(RoundedRectangle(cornerRadius: RefRadius.card,
                                                            style: .continuous))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // The strip scrolls inside itself; the page must not scroll
                // sideways with it.
                .frame(height: height)
            }
            .padding(.bottom, 18)
            .task(id: team) { await load() }
        } else {
            // Still needs somewhere to run the load from, and an empty view
            // with a task is the honest way to have no layout at all.
            Color.clear
                .frame(height: 0)
                .task(id: team) { await load() }
        }
    }

    private func load() async {
        images = []
        // Alliance pages have a label, not a team number, and no robot.
        guard team.allSatisfy({ $0.isNumber || $0.isLetter }),
              team.contains(where: \.isNumber) else { return }

        let data = await loader.photos(team)
        #if canImport(UIKit)
        images = data.compactMap { UIImage(data: $0) }.map { Image(uiImage: $0) }
        #endif
    }
}
#endif
