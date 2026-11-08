import SwiftUI

/// An 8×8 pixel badge from rows of "#" and ".".
struct PixelBadgeIcon: View {
    let rows: [String]
    var color: Color
    var pixel: CGFloat = 4

    var body: some View {
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)),
                             with: .color(color))
                }
            }
        }
        .frame(width: 8 * pixel, height: 8 * pixel)
    }
}

/// The achievements showcase and "past the cloud" stats — a tab in Settings.
struct AchievementsView: View {
    @ObservedObject private var store = Achievements.shared
    @Environment(\.palette) private var p

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                stat(formatBytes(store.stats.bytes), L("перенесено"))
                stat("\(store.stats.files)", L("файлов"))
                stat("\(store.stats.photos)", L("фото с камеры"))
                stat("\(store.unlocked.count)/\(Achievements.all.count)", L("значков"))
            }
            if let joke = store.monthJoke {
                Text(joke.replacingOccurrences(of: "‖ ", with: ""))
                    .font(AppFont.pixel(12)).foregroundStyle(p.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(Achievements.all) { a in badge(a) }
            }
        }
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(AppFont.pixel(18)).foregroundStyle(p.text)
            Text(title).font(AppFont.body(11)).foregroundStyle(p.muted)
        }
    }

    private func badge(_ a: Achievement) -> some View {
        let on = store.isUnlocked(a)
        let hidden = a.secret && !on
        return VStack(spacing: 8) {
            PixelBadgeIcon(rows: hidden ? Self.question : a.icon, color: on ? p.accent : p.muted.opacity(0.5))
                .padding(10)
                .background(StepRect(step: 3).fill(on ? p.accent.opacity(0.14) : p.surface))
                .overlay(StepRect(step: 3).stroke(on ? p.accent : p.line, lineWidth: 2))
            Text(hidden ? L("Секрет") : a.title)
                .font(AppFont.body(11, .semibold)).multilineTextAlignment(.center)
                .foregroundStyle(on ? p.text : p.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .help(hidden ? L("Откроется, когда найдёшь") : a.detail)
        .opacity(on ? 1 : 0.75)
    }

    private static let question = ["..####..", ".#....#.", "......#.", ".....#..", "....#...", "....#...", "........", "....#..."]
}
