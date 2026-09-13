//
//  RefTheme.swift
//  FRC Head Ref Helper
//
//  The single source of truth for colour and type, lifted from the
//  "Ref Notebook" design (turn 2). Every screen pulls from here, so a
//  change to the palette or the type scale happens in exactly one place.
//

import SwiftUI

// MARK: - Hex convenience

extension Color {
    /// Builds a Color from a 0xRRGGBB literal so the values below can be read
    /// straight across from the design's CSS without hand-converting to 0...1.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Palette

enum RefColor {
    /// Base the whole field backdrop sits on.
    static let void = Color(hex: 0x07080A)

    /// "Paper" — the bone-white used for primary buttons and selected chips.
    /// The design always draws it at 95-96% opacity, never pure white.
    static let paper = Color(hex: 0xF5F3EE, opacity: 0.95)
    static let ink = Color(hex: 0x111111)

    /// Gold is the app's one accent: the compose button, selection, escalation.
    static let gold = Color(hex: 0xC9A227)
    static let goldBright = Color(hex: 0xE8BE2C)   // the paused/break banner
    static let goldEdge = Color(hex: 0xC79A12)     // that banner's border
    static let goldPale = Color(hex: 0xF7E39A)     // rule codes, big timer digits
    static let goldText = Color(hex: 0xE8CF74)     // inline links and counters
    static let breakInk = Color(hex: 0x1B1503)     // text on the gold banner

    /// Alliance colours. `bar` is the saturated marker on a row; `text` is the
    /// legible tint used when the number itself is coloured.
    static let redBar = Color(hex: 0xCE3A3A)
    static let redText = Color(hex: 0xFF9F9F)
    static let redWatch = Color(hex: 0xFF6B6B)
    static let blueBar = Color(hex: 0x2E5ED6)
    static let blueText = Color(hex: 0xA5C0FF)
    static let blueWatch = Color(hex: 0x7D9BFF)

    /// Status.
    static let live = Color(hex: 0x7EE08A)
    static let liveInk = Color(hex: 0x0A1A0D)

    // Glass tints — the translucent fills layered over a material.
    static let glassTint = Color(hex: 0x181B22)     // big containers
    static let sheetTint = Color(hex: 0x141D1D)     // the compose sheet
    static let chromeTint = Color(hex: 0x14171D)    // tab bar and toast
}

// MARK: - Typography
//
// Everything uses the system font. The design called for Instrument Sans and
// IBM Plex Mono, but a condensed mono face at 11-13px is hard to read across a
// field under arena lighting, which is exactly when this app gets used.
//
// Both helpers take the design's point size and map it onto the nearest
// **Dynamic Type text style**, so text scales with the reader's accessibility
// settings instead of being pinned to a fixed size. Call sites keep the
// design's numbers; the mapping happens here.

enum RefFont {
    /// Body and UI text.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(style(for: size), weight: weight)
    }

    /// Text whose digits must stay column-aligned and must not jitter as a
    /// clock ticks — team numbers, match codes, countdowns. Same system font,
    /// monospaced digits only.
    static func numeric(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(style(for: size), weight: weight).monospacedDigit()
    }

    private static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12.5: .caption
        case ..<14.5: .footnote
        case ..<16.5: .subheadline
        case ..<19: .body
        case ..<22: .title3
        case ..<28: .title2
        case ..<40: .title
        default: .largeTitle
        }
    }
}

extension View {
    /// Letter-spacing from the design is deliberately not applied: tracking
    /// tuned for a web mockup works against legibility at a glance. Kept as a
    /// no-op so the design's intent stays discoverable in history.
    @available(*, deprecated, message: "Tracking is no longer applied; remove the call.")
    func tracked(em: CGFloat, at size: CGFloat) -> some View { self }
}

// MARK: - Card-state tint
//
// A team's compact badge ("Y", "R", "2W", "N") should read as what it is
// without being decoded. Shared so the phone, the watch and the Live Activity
// colour it identically.

extension RefColor {
    /// Background for a compact card-state badge.
    static func badgeTint(for badge: String) -> Color {
        switch badge.first {
        case "R": Color(hex: 0xD64040)      // red card
        case "Y": Color(hex: 0xE0B93A)      // yellow card
        case "N": Color.white.opacity(0.5)  // note only
        default: RefColor.gold              // verbal warnings
        }
    }

    /// Legible foreground on top of `badgeTint(for:)`.
    static func badgeInk(for badge: String) -> Color {
        badge.first == "R" ? .white : Color(hex: 0x17140A)
    }
}

// MARK: - Radii
//
// The design nests rounded rectangles concentrically: an outer container at 28
// holding rows at 21, and so on. Naming them keeps that relationship visible.

enum RefRadius {
    static let container: CGFloat = 28
    static let card: CGFloat = 24
    static let row: CGFloat = 22
    static let innerRow: CGFloat = 21
    static let control: CGFloat = 20
    static let chip: CGFloat = 14
    static let badge: CGFloat = 9
    static let sheet: CGFloat = 42
}
