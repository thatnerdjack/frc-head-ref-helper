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
//  This view does no fetching and holds no state of its own. The event's
//  avatars arrive in a single response (see TeamAvatarStore), so there is
//  nothing per-row to kick off — a row either finds its team in the store or
//  draws the placeholder.
//

import SwiftUI

struct TeamAvatarView: View {
    let team: String
    var size: CGFloat = 34

    @Environment(TeamAvatarStore.self) private var store

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
    }

    var body: some View {
        Group {
            if let image = store.image(for: team) {
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
    }
}
