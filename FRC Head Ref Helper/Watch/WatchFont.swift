//
//  WatchFont.swift
//  FRC Head Ref Helper
//
//  The watch's own type ramp.
//
//  `RefFont` (Shared/RefTheme.swift) takes the design's iOS point size and maps
//  it onto the nearest Dynamic Type TEXT STYLE. That mapping is calibrated for
//  a phone, and watchOS sizes the same style names for a screen a fifth the
//  area: asking `RefFont` for "17" on the watch lands on `.body`, which is not
//  17 there, and asking for "11" and "10" lands both of them on `.caption`.
//  Sizes that were distinct in the design collapsed into each other, and sizes
//  that were meant to match drifted apart. Nothing on the watch sat on a ramp.
//
//  So the watch gets faces named by ROLE instead of by point size. Every one is
//  built from a watchOS text style, so all of it still scales with the wearer's
//  text-size setting — which matters more here than on the phone, because this
//  screen is read at arm's length under arena lighting.
//
//  Deliberately NOT in Shared/: that folder compiles into the RefWidgets
//  extension too, and none of this applies there.
//

#if os(watchOS)
import SwiftUI

enum WatchFont {
    /// The headline countdown — the one number the watch exists to show.
    /// Rounded because rounded digits resolve faster at a glance, monospaced
    /// so the clock does not reflow on every tick.
    static let clock = Font.system(.largeTitle, design: .rounded, weight: .semibold)
        .monospacedDigit()

    /// A match code standing on its own: "Q41", "Q42 (replay 2)".
    static let matchCode = Font.system(.title3, design: .rounded, weight: .semibold)
        .monospacedDigit()

    /// A team number in a row — the second-most-scanned thing on this screen,
    /// so it gets the heaviest weight in the body range rather than a size of
    /// its own.
    static let teamNumber = Font.system(.headline, design: .rounded, weight: .semibold)
        .monospacedDigit()

    /// The value side of a labelled row: a queue state, a countdown, a count.
    static let value = Font.system(.footnote, weight: .semibold).monospacedDigit()

    /// The label side of a labelled row, and row subtitles.
    static let label = Font.system(.footnote)

    /// Quiet supporting text: section headers, "unofficial", "not at the
    /// field". The bottom of the ramp — anything smaller is unreadable across
    /// a field, so there is deliberately no step below this one.
    static let caption = Font.system(.caption2, weight: .medium)

    /// The compact card-state badge ("R", "Y", "2W", "N"). Bold because it is
    /// the smallest thing here that has to survive a glance.
    static let badge = Font.system(.caption2, weight: .bold).monospacedDigit()
}
#endif
