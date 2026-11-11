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
    @ObservedObject private var wardrobe = Wardrobe.shared
    @Environment(\.palette) private var p
    @State private var frame = 0

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
            wardrobeSection.padding(.top, 10)
        }
        .task {
            // stars on the creator's hat twinkle and the propeller spins
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                frame ^= 1
            }
        }
    }

    // MARK: Wardrobe

    private let costumeColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var wardrobeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Гардероб Вироу")).font(AppFont.display(13))
                Spacer()
                Text(L("Открыто: %d из %d", wardrobe.visible.filter { wardrobe.isUnlocked($0) }.count, wardrobe.visible.count))
                    .font(AppFont.body(11)).foregroundStyle(p.muted)
            }
            Text(L("Каждый значок открывает костюм. «Как есть» — праздничные шапки по календарю."))
                .font(AppFont.body(11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: costumeColumns, spacing: 12) {
                ForEach(wardrobe.visible) { c in costumeTile(c) }
            }
        }
    }

    private func costumeTile(_ c: Costume) -> some View {
        let open = wardrobe.isUnlocked(c), on = wardrobe.selected == c
        let gold = Color(hex: 0xE9B949), violet = Color(hex: 0x8B5CF6)
        return Button { wardrobe.select(c) } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    MascotSprite(scale: 2.5, antennaUp: frame == 1, arms: .down, mood: on ? .happy : .calm, costume: c, step: 2)
                        .saturation(open ? 1 : 0)
                        .opacity(open ? 1 : 0.35)
                        .frame(width: 80, height: 76)
                    if !open {
                        Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(p.muted)
                    }
                }
                // two lines are reserved for every title, so all tiles in a row are the same height
                Text(c.title).font(AppFont.body(11, .semibold))
                    .foregroundStyle(open ? p.text : p.muted)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(height: 30, alignment: .top)
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                if c.exclusive {
                    Text(L("ЭКСКЛЮЗИВ")).font(AppFont.pixel(8)).foregroundStyle(gold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: 0x2B1E4A)))
                        .overlay(Capsule().stroke(violet, lineWidth: 1))
                        .offset(y: -7)
                }
            }
            .background(StepRect(step: 3).fill(on ? p.accent.opacity(0.16) : p.surface))
            .overlay(StepRect(step: 3).stroke(
                c.exclusive ? AnyShapeStyle(LinearGradient(colors: [violet, gold, violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(on ? p.accent : p.line),
                lineWidth: on || c.exclusive ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .help(open ? (on ? L("Надет") : L("Надеть")) : L("Откроется за значок «%@»", wardrobe.badgeTitle(c) ?? ""))
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
