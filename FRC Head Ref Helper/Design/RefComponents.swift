//
//  RefComponents.swift
//  FRC Head Ref Helper
//
//  The few pieces the system does not already give us.
//
//  Glass itself is NOT one of them: surfaces use SwiftUI's built-in
//  `.glassEffect(_:in:)` and the `.glass` / `.glassProminent` button styles,
//  so the app inherits Liquid Glass — including its motion, its behaviour over
//  scrolling content, and its accessibility fallbacks (Reduce Transparency) —
//  instead of re-deriving it from blurs and hairline borders.
//
//  What remains here is genuinely app-specific: the field-tinted backdrop, the
//  card-state badge, and two small field markers.
//

import SwiftUI

// MARK: - Backdrop

/// The field-tinted wash behind every screen: two large radial gradients, red
/// alliance against blue, blurred until no edge is legible. This is artwork
/// rather than a control, so it stays hand-drawn.
struct FieldBackdrop: View {
    enum Style {
        case field, paused, dayComplete
    }

    var style: Style = .field

    private var washes: [(color: Color, x: CGFloat, y: CGFloat)] {
        switch style {
        case .field:
            [(RefColor.redBar.opacity(0.34), 0, 0), (RefColor.blueBar.opacity(0.34), 1, 0.30)]
        case .paused:
            [(RefColor.gold.opacity(0.30), 0.5, 0), (RefColor.blueBar.opacity(0.22), 1, 0.40)]
        case .dayComplete:
            [(RefColor.redBar.opacity(0.24), 0, 0), (RefColor.blueBar.opacity(0.28), 1, 0.35)]
        }
    }

    var body: some View {
        ZStack {
            RefColor.void
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    ForEach(Array(washes.enumerated()), id: \.offset) { _, wash in
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [wash.color, wash.color.opacity(0)],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: w * 0.9
                                )
                            )
                            .frame(width: w * 2, height: h * 1.1)
                            .position(x: w * wash.x, y: h * wash.y)
                    }
                }
                .blur(radius: 60)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Card state

/// The badge trailing a team row. Deliberately a solid, saturated fill rather
/// than glass: "RED CARD" has to survive a glance across a noisy field, and
/// translucency is exactly the wrong property for it.
struct StatusBadge: View {
    let text: String
    let background: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(RefFont.numeric(12, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: RefRadius.badge, style: .continuous))
            .fixedSize()
    }
}

/// One of the three counters above a team's record and on the day-complete
/// screen. Shared because it was written twice with slightly different label
/// opacities, and because the two copies disagreed on height: a label that
/// wrapped to two lines ("Verbal warnings") made its tile taller than its
/// neighbours. `maxHeight: .infinity` equalises them across the row.
struct StatTile: View {
    let value: String
    let label: String
    var isHighlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(RefFont.numeric(30, .semibold))
                .foregroundStyle(isHighlighted ? RefColor.goldPale : .white)
            Text(label)
                .font(RefFont.text(12, .medium))
                .foregroundStyle(.white.opacity(isHighlighted ? 0.8 : 0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity)
        .glassCard(isHighlighted ? .regular.tint(RefColor.gold.opacity(0.26)) : .regular,
                   radius: RefRadius.card)
    }
}

/// The all-caps mono label heading each section.
struct SectionLabel: View {
    let text: String
    var opacity: Double = 0.55

    var body: some View {
        Text(text)
            .font(RefFont.numeric(12, .medium))
            .foregroundStyle(.white.opacity(opacity))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}

// MARK: - Field markers

/// The short vertical bar marking which alliance a team is on.
struct AllianceBar: View {
    let color: Color
    var height: CGFloat = 30
    var width: CGFloat = 4

    var body: some View {
        Capsule().fill(color).frame(width: width, height: height)
    }
}

/// Stands in for a team avatar until logos are loaded.
struct TeamLogoPlaceholder: View {
    var size: CGFloat = 34

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Color.white.opacity(0.06))
            .overlay {
                GeometryReader { geo in
                    Path { path in
                        var x = -geo.size.height
                        while x < geo.size.width + geo.size.height {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x + geo.size.height, y: geo.size.height))
                            x += 8
                        }
                    }
                    .stroke(Color.white.opacity(0.13), lineWidth: 4)
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .frame(width: size, height: size)
            .clipShape(shape)
    }
}

// MARK: - Shape helper

extension View {
    /// Applies the system glass effect in a continuous rounded rectangle.
    /// A one-line spelling of the two things every surface here needs, so the
    /// corner style stays consistent — the effect itself is entirely SwiftUI's.
    func glassCard(_ glass: Glass = .regular, radius: CGFloat) -> some View {
        glassEffect(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
