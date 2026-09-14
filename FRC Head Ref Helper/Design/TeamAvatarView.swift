//
//  TeamAvatarView.swift
//  FRC Head Ref Helper
//
//  A team's avatar where there is one, and the hatched placeholder where there
//  is not.
//
//  The size is fixed and the frame is reserved whether or not an image ever
//  arrives. That is not fussiness: rows in this app must be the same height as
//  each other, and a previous round shipped a ragged next-match card precisely
//  because a piece of conditional content collapsed to nothing. An avatar that
//  is still loading, or that does not exist, occupies exactly the space it
//  would have occupied.
//

import SwiftUI

/// Supplies the bytes for a team's avatar.
///
/// Nil today — nothing fetches yet. When the frc.events client lands it
/// provides one of these and every avatar in the app starts working at once.
nonisolated struct TeamMediaLoader: Sendable {
    let avatar: @Sendable (_ team: String) async -> Data?

    static let none = TeamMediaLoader { _ in nil }
}

private struct TeamMediaLoaderKey: EnvironmentKey {
    static let defaultValue = TeamMediaLoader.none
}

extension EnvironmentValues {
    var teamMediaLoader: TeamMediaLoader {
        get { self[TeamMediaLoaderKey.self] }
        set { self[TeamMediaLoaderKey.self] = newValue }
    }
}

struct TeamAvatarView: View {
    let team: String
    var size: CGFloat = 34

    @Environment(\.teamMediaLoader) private var loader
    @State private var image: Image?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
    }

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                TeamLogoPlaceholder(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: team) { await load() }
    }

    private func load() async {
        image = nil
        let key = "avatar-\(team)"
        let result = await TeamMediaCache.shared.media(for: key) {
            await loader.avatar(team)
        }
        guard case .image(let data) = result else { return }
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return }
        image = Image(uiImage: ui)
        #endif
    }
}
