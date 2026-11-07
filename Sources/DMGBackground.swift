#if DEBUG
import SwiftUI

/// Фон окна DMG 640×400: логотип, подсказка и стрелка от приложения к «Программам».
/// Координаты иконок должны совпадать с scripts/dmg-settings.py.
struct DMGBackground: View {
    static let size = CGSize(width: 640, height: 400)
    static let appX: CGFloat = 160, appsX: CGFloat = 480, iconY: CGFloat = 196

    private let gold = Color(hex: 0xE9B949)
    private let muted = Color(hex: 0xA3959F)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x241B28), Color(hex: 0x17121A)],
                           startPoint: .top, endPoint: .bottom)

            // Тёплый отсвет за стрелкой.
            Ellipse().fill(gold.opacity(0.10))
                .frame(width: 420, height: 180).blur(radius: 60)
                .position(x: 320, y: Self.iconY)

            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    DroidMark(size: 24)
                    Text("Shuttle")
                        .font(AppFont.display(22, .bold))
                        .foregroundStyle(Color(hex: 0xF2EAE0))
                }
                Text("Перетащите Shuttle в «Программы»")
                    .font(AppFont.body(13))
                    .foregroundStyle(muted)
            }
            .position(x: 320, y: 62)

            arrow.position(x: 320, y: Self.iconY)

            // Плашки под подписями Finder: читаются и белые, и чёрные буквы.
            ForEach([Self.appX, Self.appsX], id: \.self) { x in
                Capsule().fill(Color(hex: 0x7A6C76).opacity(0.9))
                    .frame(width: 128, height: 26)
                    .position(x: x, y: Self.iconY + 74)
            }

            Text("macOS 14+ · Apple Silicon и Intel")
                .font(AppFont.body(11))
                .foregroundStyle(muted.opacity(0.7))
                .position(x: 320, y: 372)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var arrow: some View {
        Canvas { ctx, s in
            let y = s.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 8, y: y))
            line.addLine(to: CGPoint(x: s.width - 22, y: y))
            ctx.stroke(line, with: .color(gold.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 12]))
            var head = Path()
            head.move(to: CGPoint(x: s.width - 26, y: y - 13))
            head.addLine(to: CGPoint(x: s.width - 8, y: y))
            head.addLine(to: CGPoint(x: s.width - 26, y: y + 13))
            ctx.stroke(head, with: .color(gold),
                       style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 150, height: 40)
        .shadow(color: gold.opacity(0.5), radius: 8)
    }
}
#endif
