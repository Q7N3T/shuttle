import SwiftUI

/// The Wirrow logo: a golden capsule droid with two antennas,
/// and ‹ › arrows for eyes (file exchange).
struct DroidMark: View {
    var size: CGFloat = 22
    var color: Color = Color(hex: 0xE9B949)
    var eyes: Color = Color(hex: 0x2A1E05)
    var glow: Bool = true

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let stroke = w * 0.075

            // Antennas
            var ant = Path()
            ant.move(to: CGPoint(x: w * 0.34, y: h * 0.36))
            ant.addLine(to: CGPoint(x: w * 0.24, y: h * 0.13))
            ant.move(to: CGPoint(x: w * 0.66, y: h * 0.36))
            ant.addLine(to: CGPoint(x: w * 0.76, y: h * 0.13))
            ctx.stroke(ant, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            for x in [0.24, 0.76] {
                let r = w * 0.065
                ctx.fill(Path(ellipseIn: CGRect(x: w * x - r, y: h * 0.13 - r, width: r * 2, height: r * 2)),
                         with: .color(color))
            }

            // Capsule head
            let head = CGRect(x: w * 0.06, y: h * 0.34, width: w * 0.88, height: h * 0.54)
            ctx.fill(Path(roundedRect: head, cornerRadius: head.height / 2), with: .color(color))

            // Arrow eyes ‹ ›
            let cy = head.midY, eh = h * 0.12, ew = w * 0.075
            var e = Path()
            let lx = w * 0.36
            e.move(to: CGPoint(x: lx + ew / 2, y: cy - eh))
            e.addLine(to: CGPoint(x: lx - ew / 2, y: cy))
            e.addLine(to: CGPoint(x: lx + ew / 2, y: cy + eh))
            let rx = w * 0.64
            e.move(to: CGPoint(x: rx - ew / 2, y: cy - eh))
            e.addLine(to: CGPoint(x: rx + ew / 2, y: cy))
            e.addLine(to: CGPoint(x: rx - ew / 2, y: cy + eh))
            ctx.stroke(e, with: .color(eyes),
                       style: StrokeStyle(lineWidth: stroke * 0.95, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .shadow(color: glow ? color.opacity(0.55) : .clear, radius: size * 0.35)
    }
}

#Preview {
    HStack(spacing: 24) {
        DroidMark(size: 22)
        DroidMark(size: 64)
        DroidMark(size: 128, glow: false)
    }
    .padding(40)
    .background(Color(hex: 0x17121A))
}

/// The app icon: a plum macOS squircle and the golden droid.
/// Drawn at 1024×1024 on Apple's grid (824 field with a 100 inset).
struct AppIconView: View {
    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2B2130), Color(hex: 0x17121A)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(Color(hex: 0x3A2E3F), lineWidth: 6))
                .overlay(
                    // A warm glow behind the droid.
                    Circle().fill(Color(hex: 0xE9B949).opacity(0.16))
                        .frame(width: 560, height: 560).blur(radius: 90).offset(y: 30))
                .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
            DroidMark(size: 540, glow: false)
                .shadow(color: Color(hex: 0xE9B949).opacity(0.45), radius: 40)
                .offset(y: 6)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Switch icon: two golden Joy-Con halves with dark sticks.
struct JoyConMark: View {
    var size: CGFloat = 18
    var color: Color = Color(hex: 0xE9B949)

    /// The Switch icon in our color: the left half is an outline with a dot at the top,
    /// the right half is filled, with a dot-shaped hole at the bottom.
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let line = w * 0.085
            let top = h * 0.08, bottom = h * 0.92, gap = w * 0.07
            let half = (w * 0.80 - gap) / 2
            let outer = half * 0.9, inner = w * 0.035
            let left = CGRect(x: w * 0.10, y: top, width: half, height: bottom - top)
            let right = CGRect(x: left.maxX + gap, y: top, width: half, height: bottom - top)
            // left: outline (drawn inside its bounds)
            let lIn = left.insetBy(dx: line / 2, dy: line / 2)
            let l = UnevenRoundedRectangle(topLeadingRadius: outer - line / 2, bottomLeadingRadius: outer - line / 2,
                                           bottomTrailingRadius: inner, topTrailingRadius: inner,
                                           style: .continuous).path(in: lIn)
            ctx.stroke(l, with: .color(color), lineWidth: line)
            let rad = half * 0.2
            let c1 = CGPoint(x: left.midX + half * 0.04, y: top + (bottom - top) * 0.28)
            ctx.fill(Path(ellipseIn: CGRect(x: c1.x - rad, y: c1.y - rad, width: rad * 2, height: rad * 2)),
                     with: .color(color))
            // right: fill with a hole
            let r = UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner,
                                           bottomTrailingRadius: outer, topTrailingRadius: outer,
                                           style: .continuous).path(in: right)
            ctx.fill(r, with: .color(color))
            let c2 = CGPoint(x: right.midX - half * 0.04, y: top + (bottom - top) * 0.56)
            ctx.blendMode = .destinationOut
            ctx.fill(Path(ellipseIn: CGRect(x: c2.x - rad, y: c2.y - rad, width: rad * 2, height: rad * 2)),
                     with: .color(.black))
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }
}
