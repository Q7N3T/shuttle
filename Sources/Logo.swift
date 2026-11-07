import SwiftUI

/// Логотип Shuttle: золотой дроид-капсула с двумя антеннами,
/// вместо глаз — стрелки ‹ › (обмен файлами).
struct DroidMark: View {
    var size: CGFloat = 22
    var color: Color = Color(hex: 0xE9B949)
    var eyes: Color = Color(hex: 0x2A1E05)
    var glow: Bool = true

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let stroke = w * 0.075

            // Антенны
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

            // Голова-капсула
            let head = CGRect(x: w * 0.06, y: h * 0.34, width: w * 0.88, height: h * 0.54)
            ctx.fill(Path(roundedRect: head, cornerRadius: head.height / 2), with: .color(color))

            // Глаза-стрелки ‹ ›
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

/// Иконка приложения: сливовый «сквиркл» macOS и золотой дроид.
/// Рисуется в 1024×1024 по сетке Apple (поле 824 с отступом 100).
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
                    // Тёплый отсвет за дроидом.
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
