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
//  The loader hands back URLs, not bytes. The Blue Alliance serves robot photos
//  as ordinary image URLs, so `AsyncImage` fetches them and `URLCache` caches
//  them — both on disk and in memory, keyed and evicted by the system. An
//  earlier version pulled `Data` through a hand-written cache that, as it
//  happened, this view never used.
//
//  NOTHING HERE FETCHES YET. The loader comes from the environment and no one
//  supplies a real one until The Blue Alliance client lands.
//

#if !os(watchOS)
import SwiftUI

/// Supplies robot photo URLs for a team.
nonisolated struct RobotPhotoLoader: Sendable {
    /// Ordered newest first — this season's robot is the one being asked about.
    let photos: @Sendable (_ team: String) async -> [URL]

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
    @State private var urls: [URL] = []

    private let height: CGFloat = 132

    var body: some View {
        // The `.task` hangs off the Group, which is always present, NOT off the
        // branches of the `if`.
        //
        // It used to be on both branches, and that was an infinite loop waiting
        // for a real loader: the task set `urls`, which flipped the condition,
        // which destroyed the branch the task was attached to and created the
        // other one, whose task fired and cleared `urls`, which flipped the
        // condition back. Each lap issued another fetch. It never fired only
        // because `RobotPhotoLoader.none` returns nothing, so the condition
        // never flipped in the first place.
        //
        // An empty `if` inside a Group is `EmptyView`, so "no photos, no
        // layout" still holds — there is simply one view identity now instead
        // of two that replace each other.
        Group {
            if !urls.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "ROBOT")

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(urls, id: \.self) { url in
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .interpolation(.high)
                                            .aspectRatio(contentMode: .fill)
                                    default:
                                        // A photo that is still arriving, or
                                        // that failed, holds its place rather
                                        // than reflowing the strip under the
                                        // referee's thumb.
                                        Color.white.opacity(0.06)
                                    }
                                }
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
            }
        }
        .task(id: team) { await load() }
    }

    private func load() async {
        // Alliance pages have a label, not a team number, and no robot.
        guard team.allSatisfy({ $0.isNumber || $0.isLetter }),
              team.contains(where: \.isNumber) else {
            urls = []
            return
        }

        let found = await loader.photos(team)
        // Checked because `.task(id:)` cancels on a team change, and a late
        // reply from the previous team must not land on this one's page.
        guard !Task.isCancelled else { return }
        urls = found
    }
}
#endif
