// DesignSystem.swift — TRI-NET UI kit.
//
// A near-monochrome, editorial system inspired by the xAI/Grok language:
// jet-ink surfaces, hairline rings instead of shadows, fully-rounded pills as
// the signature shape, a sans UI face with a mono face for technical data,
// and a single high-contrast white fill for the primary action. Flat and
// restrained — depth comes from hairlines and spacing, not blur or shadow.
//
// This is the shared vocabulary for every tab and the header. See BRANDBOOK.md.
import SwiftUI

enum DS {
    // MARK: Surfaces (jet ink → charcoal)
    static let ink = Color(red: 0.039, green: 0.039, blue: 0.039)      // #0a0a0a app base
    static let surface = Color(red: 0.082, green: 0.082, blue: 0.082)  // #151515 panels
    static let surfaceHi = Color(red: 0.12, green: 0.12, blue: 0.12)   // hover / raised

    // MARK: Hairlines (rings, never shadows)
    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.20)

    // MARK: Text
    static let text = Color.white.opacity(0.95)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)

    // MARK: Accent — monochrome. One high-contrast white fill for the CTA.
    static let fill = Color.white
    static let onFill = Color.black
    // Semantic (used sparingly, only for live signals)
    static let live = Color(red: 0.30, green: 0.85, blue: 0.45)  // connected/active dot
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.35) // end/stop

    // MARK: Type — sans for UI, mono for technical data (ids, counters, ip)
    static func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w) }
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w, design: .monospaced) }
    static func display(_ s: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: s, weight: w) }

    // MARK: Metrics
    static let radius: CGFloat = 12      // cards
    static let pad: CGFloat = 14
}

// MARK: - Components

// Hairline divider.
struct Hairline: View {
    var body: some View { Rectangle().fill(DS.hairline).frame(height: 1) }
}

// Card: charcoal surface ringed by a hairline (no shadow).
struct DSCard: ViewModifier {
    var radius: CGFloat = DS.radius
    func body(content: Content) -> some View {
        content
            .background(DS.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(DS.hairline, lineWidth: 1))
    }
}
extension View {
    func dsCard(_ r: CGFloat = DS.radius) -> some View { modifier(DSCard(radius: r)) }
}

// Signature pill button. `filled` = the one white CTA; otherwise a hairline
// outline pill. `compact` shrinks padding for toolbars.
struct PillButton: View {
    let title: String
    var icon: String? = nil
    var filled: Bool = false
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: compact ? 10 : 12)) }
                Text(title).font(DS.ui(compact ? 11 : 13, filled ? .semibold : .medium))
            }
            .foregroundColor(filled ? DS.onFill : DS.text)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 9)
            .background(filled ? DS.fill : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(filled ? Color.clear : DS.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// Tab pill for the primary nav. Active = subtle fill + hairline; inactive = dim.
struct TabPill: View {
    let title: String
    let icon: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(DS.ui(12, active ? .semibold : .regular))
            }
            .foregroundColor(active ? DS.text : DS.dim)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(active ? Color.white.opacity(0.08) : Color.clear, in: Capsule())
            .overlay(active ? Capsule().stroke(DS.hairline, lineWidth: 1) : nil)
        }
        .buttonStyle(.plain)
    }
}

// Small round icon control (hairline ring).
struct IconPill: View {
    let system: String
    var active: Bool = false
    var tint: Color = DS.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15))
                .foregroundColor(active ? tint : DS.text)
                .frame(width: 40, height: 40)
                .overlay(Circle().stroke(active ? tint.opacity(0.6) : DS.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// Status dot + label (mono).
struct StatusTag: View {
    let text: String
    var live: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(live ? DS.live : DS.faint).frame(width: 6, height: 6)
            Text(text.uppercased()).font(DS.mono(10, .medium)).tracking(0.5)
                .foregroundColor(live ? DS.text : DS.dim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
    }
}

// Section label — uppercase mono, faint.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(DS.mono(10, .medium)).tracking(1.2)
            .foregroundColor(DS.faint)
    }
}
