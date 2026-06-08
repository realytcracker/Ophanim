//
//  Theme.swift
//  Ophanim
//
//  Central "hackery" theme: dark slate surfaces with phosphor-green accents, system monospace
//  everywhere, plus optional theatrics (digital rain, scanlines, glow) gated behind a single
//  app-wide toggle (`ophanim.fx.enabled`). Apply `.ophanimTheme()` at a window/scene root.
//

import SwiftUI
import Foundation   // sin() for the wind / sweep animations

// MARK: - Palette

enum Theme {
    // Surfaces - near-black slate, slightly green-shifted.
    static let bg            = Color(hex: 0x0A0E0B)
    static let surface       = Color(hex: 0x111712)
    static let surfaceRaised = Color(hex: 0x18211A)
    static let border        = Color(hex: 0x254A30)

    // Greens - primary accent / highlight / dim.
    static let accent        = Color(hex: 0x3CE07A)   // primary green
    static let accentBright  = Color(hex: 0x7CFFB0)   // headings / glow
    static let accentDim     = Color(hex: 0x2B8F52)

    // Purples - secondary accent (selection, active/intercept states, alternating headings).
    static let purple        = Color(hex: 0xB36CFF)
    static let purpleBright  = Color(hex: 0xD7B0FF)
    static let purpleDim     = Color(hex: 0x7E4FB8)

    // Text.
    static let textPrimary   = Color(hex: 0xCBF5D6)   // soft green-white
    static let textSecondary = Color(hex: 0x6FA982)   // dim green-gray
    static let danger        = Color(hex: 0xFF5C5C)

    // Fonts - system monospaced at semantic-ish sizes.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let title   = mono(18, .bold)
    static let heading = mono(13, .semibold)
    static let body    = mono(12, .regular)
    static let caption = mono(10, .regular)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Theme application

/// Root modifier: dark scheme, green tint, monospace everywhere, slate background, and (when the
/// fx toggle is on) a faint scanline overlay. Apply once per window/scene root.
struct OphanimThemeModifier: ViewModifier {
    @AppStorage("ophanim.fx.enabled") private var fxEnabled = true

    @AppStorage("ophanim.rain.enabled") private var rainEnabled = false
    @AppStorage("ophanim.fx.eyes") private var eyesEnabled = true

    func body(content: Content) -> some View {
        content
            .monospacedEverywhere()
            .tint(Theme.accent)
            .foregroundColor(Theme.textPrimary)
            .background {
                // Slate base + (when fx is on) faint background effects behind ALL content, so every
                // themed window - editors, the options/settings sheets, the log viewer - shares them,
                // not just the library. Content sits on top; effects show through margins and
                // transparent areas.
                ZStack {
                    Theme.bg
                    if fxEnabled && rainEnabled {
                        DigitalRainView().opacity(0.16).allowsHitTesting(false)
                    }
                    if fxEnabled && eyesEnabled {
                        EyeballsView().opacity(0.78).allowsHitTesting(false)
                    }
                }
                .ignoresSafeArea()
            }
            .overlay {
                if fxEnabled {
                    ScanlineOverlay().allowsHitTesting(false).ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
    }
}

private struct MonospaceEverywhere: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.fontDesign(.monospaced)
        } else {
            content.font(.system(.body, design: .monospaced))
        }
    }
}

extension View {
    func ophanimTheme() -> some View { modifier(OphanimThemeModifier()) }
    func monospacedEverywhere() -> some View { modifier(MonospaceEverywhere()) }

    /// Phosphor glow for headings/accents - no-op when effects are disabled.
    func phosphorGlow(_ color: Color = Theme.accent, radius: CGFloat = 4) -> some View {
        modifier(GlowModifier(color: color, radius: radius))
    }
}

private struct GlowModifier: ViewModifier {
    @AppStorage("ophanim.fx.enabled") private var fxEnabled = true
    let color: Color
    let radius: CGFloat
    func body(content: Content) -> some View {
        if fxEnabled {
            content.shadow(color: color.opacity(0.7), radius: radius)
        } else {
            content
        }
    }
}

// MARK: - Control styles

/// Terminal-style button: green outline, monospace, fills on hover/press.
struct TerminalButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill((configuration.isPressed || hovering) ? Theme.accent.opacity(0.18) : Theme.surfaceRaised)
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
            .foregroundColor(Theme.accent)
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Green-on-slate monospace text field with a thin border.
struct TerminalTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
    }
}

/// Bordered "card" group box with a green title and slate fill.
struct TerminalGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(Theme.heading)
                .foregroundColor(Theme.accentBright)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Effects

/// Faint CRT scanlines plus a slow bright "refresh" band that sweeps down the screen, and an
/// occasional brief horizontal-tear glitch. Cheap; the static lines are drawn each frame and the
/// sweep/glitch are simple time functions.
struct ScanlineOverlay: View {
    @AppStorage("ophanim.fx.sweep")  private var sweepEnabled = true
    @AppStorage("ophanim.fx.glitch") private var glitchEnabled = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // static scanlines - darken (multiply)
                ctx.blendMode = .multiply
                let line: CGFloat = 3
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(Color.black.opacity(0.18)))
                    y += line
                }
                // sweep + glitch - brighten (plusLighter)
                ctx.blendMode = .plusLighter
                // slow vertical refresh sweep: a soft bright band traveling top->bottom every ~7s
                if sweepEnabled {
                    let period = 7.0
                    let bandH = size.height * 0.22
                    let sweepY = CGFloat((t.truncatingRemainder(dividingBy: period)) / period)
                                  * (size.height + bandH) - bandH
                    let band = Path(CGRect(x: 0, y: sweepY, width: size.width, height: bandH))
                    ctx.fill(band, with: .linearGradient(
                        Gradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.05),
                                          Theme.accent.opacity(0)]),
                        startPoint: CGPoint(x: 0, y: sweepY),
                        endPoint: CGPoint(x: 0, y: sweepY + bandH)))
                }
                // sparse horizontal tear glitch: a thin bright line that jumps to a new row in bursts
                if glitchEnabled && Int(t * 3) % 67 < 2 {
                    let gy = CGFloat(Int(t * 53) % max(1, Int(size.height)))
                    ctx.fill(Path(CGRect(x: 0, y: gy, width: size.width, height: 1.5)),
                             with: .color(Theme.accentBright.opacity(0.22)))
                }
            }
        }
    }
}

/// Falling green glyphs ("digital rain"). Use as a background in empty states / sidebars.
/// Self-animating via TimelineView; honors the fx toggle (renders nothing when disabled).
struct DigitalRainView: View {
    // Digital rain is its own opt-in, default OFF. `preview` forces it on (used by the settings preview).
    @AppStorage("ophanim.rain.enabled") private var rainEnabled = false
    // Sub-effect toggles (default ON): each refines the rain when it's enabled.
    @AppStorage("ophanim.fx.wind")   private var windEnabled = true
    @AppStorage("ophanim.fx.glitch") private var glitchEnabled = true
    @AppStorage("ophanim.fx.surge")  private var surgeEnabled = true
    var preview = false
    var columnWidth: CGFloat = 14
    var glyphs = Array("01ｱｲｳｴｵｶｷｸ日ﾊﾋﾌﾍﾎ010101$#%&XZ")

    var body: some View {
        if rainEnabled || preview {
            TimelineView(.periodic(from: .now, by: 0.09)) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let cols = max(1, Int(size.width / columnWidth))
                    let rows = max(1, Int(size.height / columnWidth))
                    let tick = Int(t / 0.09)
                    // WIND: a slowly gusting horizontal lean (two sines = a base sway plus gusts). It is
                    // applied proportionally to a glyph's depth down the view, so the top stays put while
                    // lower rows drift - the streaks slant, and the slant reverses as the wind shifts. A
                    // falling glyph therefore curves as it descends, like rain blown in the wind.
                    let gust = sin(t * 0.23) * 0.7 + sin(t * 0.071 + 1.3) * 0.3        // -1..1, gusting
                    let windPx = windEnabled ? gust * Double(columnWidth) * 3.5 : 0     // max lean ~3.5 cols
                    for c in 0..<cols {
                        // Deterministic per-column phase/speed (no Math.random - stable & resumable).
                        let speed = 1 + (c * 7 % 4)
                        let phase = (c * 13) % rows
                        let head = (tick / speed + phase) % (rows + 8)
                        // per-column surge: every so often a whole trail momentarily brightens
                        let surge = surgeEnabled && ((tick / speed + c * 5) % 41) < 3
                        for r in 0..<rows {
                            let dist = head - r
                            guard dist >= 0 && dist < 10 else { continue }
                            let g = glyphs[(r * 31 + c * 17 + tick / speed) % glyphs.count]
                            let bright = dist == 0
                            var opacity = bright ? 1.0 : max(0, 0.5 - Double(dist) * 0.06)
                            if surge { opacity = min(1.0, opacity + 0.3) }
                            // Roughly every third column rains purple instead of green (two-tone).
                            let purpleColumn = c % 3 == 1
                            let baseBright = purpleColumn ? Theme.purpleBright : Theme.accentBright
                            let baseDim = purpleColumn ? Theme.purple : Theme.accent
                            var color = bright ? baseBright : baseDim
                            // GLITCH: a sparse, moving set of head glyphs flash white for a frame.
                            if glitchEnabled && bright && (c * 17 + tick * 5) % 197 < 1 { color = .white; opacity = 1 }
                            // wind drift, proportional to depth (top fixed, bottom leans most)
                            let xoff = windPx * (Double(r) / Double(max(1, rows)))
                            let text = Text(String(g)).font(Theme.mono(columnWidth - 2))
                                .foregroundColor(color.opacity(opacity))
                            ctx.draw(text, at: CGPoint(x: CGFloat(c) * columnWidth + columnWidth / 2 + CGFloat(xoff),
                                                       y: CGFloat(r) * columnWidth + columnWidth / 2))
                        }
                    }
                }
            }
        }
    }
}

/// Toggleable background effect: eyeballs fade in at random places and sizes, the eye "opens" (draws
/// itself in), blinks a few times, then fades away - an "Ophanim" nod (the many-eyed watcher). Fully
/// deterministic from the clock (no @State), like the rain, so it composes under TimelineView. Honors
/// the master fx toggle plus its own `ophanim.fx.eyes` flag.
struct EyeballsView: View {
    @AppStorage("ophanim.fx.enabled") private var fxEnabled = true
    @AppStorage("ophanim.fx.eyes")    private var eyesEnabled = true
    var preview = false
    /// Concurrent eye "slots". Each cycles independently with its own length/offset, so several are on
    /// screen at staggered points in their lifecycle at any time.
    private let slots = 7

    var body: some View {
        if (fxEnabled && eyesEnabled) || preview {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    for i in 0..<slots { drawSlot(ctx, size, t, i) }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Cheap deterministic hash → [0,1). (No Math.random: stable and resumable, matching the rain.)
    private func h(_ n: Double) -> Double { let x = sin(n) * 43758.5453; return x - x.rounded(.down) }

    private func drawSlot(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ i: Int) {
        // Each slot owns a disjoint grid cell, so two eyes can never overlap. (4x2 = 8 cells >= 7 slots.)
        let cols = 4, rows = 2
        let cw = size.width / Double(cols), ch = size.height / Double(rows)
        let cellMinX = Double(i % cols) * cw, cellMinY = Double((i / cols) % rows) * ch

        let cycleLen = 9.0 + h(Double(i) * 1.7) * 7.0                  // 9..16s per appearance
        let phase = t / cycleLen + h(Double(i) * 5.3) * 10.0
        let cyc = phase.rounded(.down)
        let p = phase - cyc                                            // 0..1 within this appearance
        let seed = Double(i) * 131.0 + cyc                            // fresh params each appearance
        // Size varies but is capped to fit inside the cell (so the eye stays in its region).
        let maxR = max(8.0, min(cw, ch) * 0.42 - 4)
        let r = min(maxR, 16.0 + h(seed * 1.7) * 52.0)
        // Random placement WITHIN the cell, clamped so the eye's bounding box stays inside it.
        let mx = r + 3, my = r * 0.62 + 3
        let cx = cellMinX + mx + h(seed * 2.3) * max(0, cw - 2 * mx)
        let cy = cellMinY + my + h(seed * 3.9) * max(0, ch - 2 * my)

        // Lifecycle: draw-in (eye opens) → hold while blinking a few times → fade out.
        let openEnd = 0.12, fadeStart = 0.80
        var open: Double, alpha: Double
        if p < openEnd {
            let q = p / openEnd
            open = q; alpha = q
        } else if p < fadeStart {
            alpha = 1
            open = 1 - blink((p - openEnd) / (fadeStart - openEnd))
        } else {
            open = 1; alpha = 1 - (p - fadeStart) / (1 - fadeStart)
        }
        guard alpha > 0.01 else { return }
        drawEye(ctx, CGPoint(x: cx, y: cy), r,
                open: max(0.04, open), alpha: alpha * 0.42, purple: h(seed * 7.1) > 0.5, t: t, seed: seed)
    }

    /// Three quick blinks across the hold window: ~0 (open) almost always, ~1 (shut) at blink instants.
    private func blink(_ hb: Double) -> Double {
        var d = 0.0
        for c in [0.25, 0.5, 0.72] {
            let x = (hb - c) / 0.03
            d = max(d, exp(-x * x))
        }
        return min(1, d)
    }

    /// Rasterized onto a coarse, screen-aligned pixel grid so the eye reads as blocky low-res "pixels"
    /// that match the terminal/CRT aesthetic (rather than smooth vector curves). Cells are snapped to a
    /// global grid so the pixels don't shimmer as the pupil drifts.
    private func drawEye(_ ctx: GraphicsContext, _ c: CGPoint, _ r: Double,
                         open: Double, alpha: Double, purple: Bool, t: Double, seed: Double) {
        let w = r, hgt = max(2.0, r * 0.62 * open)                    // lens half-extents
        let glow = purple ? Theme.purpleBright : Theme.accentBright
        let dim  = purple ? Theme.purple : Theme.accent
        let irisR = r * 0.52
        let pupR  = irisR * 0.5
        let ic = CGPoint(x: c.x + sin(t * 0.7 + seed) * r * 0.18,     // pupil drifts (looks around)
                         y: c.y + cos(t * 0.9 + seed) * r * 0.10)
        let cell = 4.0                                                // pixel size (lower = less blocky)
        let open0 = open > 0.18

        var gy = (((c.y - hgt) / cell).rounded(.down)) * cell
        let yMax = c.y + hgt
        while gy <= yMax {
            var gx = (((c.x - w) / cell).rounded(.down)) * cell
            let xMax = c.x + w
            while gx <= xMax {
                let px = gx + cell / 2, py = gy + cell / 2
                let dx = px - c.x, dy = py - c.y
                let e = (dx / w) * (dx / w) + (dy / hgt) * (dy / hgt)  // <=1 inside the lens ellipse
                if e <= 1 {
                    let di = (open0) ? hypot(px - ic.x, py - ic.y) : .infinity
                    let color: Color
                    if di < pupR {
                        color = .black.opacity(0.92 * alpha)          // pupil
                    } else if di < irisR {
                        color = ((1 - di / irisR) > 0.5 ? glow : dim).opacity(alpha)   // iris (2 quantized rings)
                    } else if e > 0.72 {
                        color = glow.opacity(alpha)                   // glowing rim (eyelid)
                    } else {
                        color = .black.opacity(0.5 * alpha)           // sclera
                    }
                    ctx.fill(Path(CGRect(x: gx, y: gy, width: cell, height: cell)), with: .color(color))
                }
                gx += cell
            }
            gy += cell
        }
        if open0 {                                                    // single bright glint pixel
            let gx = (((ic.x - pupR * 0.5) / cell).rounded(.down)) * cell
            let gyp = (((ic.y - pupR * 0.5) / cell).rounded(.down)) * cell
            ctx.fill(Path(CGRect(x: gx, y: gyp, width: cell, height: cell)),
                     with: .color(.white.opacity(0.7 * alpha)))
        }
    }
}
