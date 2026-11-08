import Foundation

/// An achievement with an 8×8 pixel badge ("#" — a filled pixel).
struct Achievement: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let icon: [String]
    /// Secret: until unlocked, the title and description are hidden.
    var secret = false
}

/// Counters and achievements. Stored in achievements.json next to the history.
@MainActor
final class Achievements: ObservableObject {
    static let shared = Achievements()

    struct Stats: Codable, Equatable {
        var bytes: UInt64 = 0
        var files = 0
        var photos = 0
        var saves = 0
        var installs = 0
        var clicks = 0
        /// Which devices were connected before: phone, console.
        var kinds: Set<String> = []
        /// One-off events: resumed, night, konami.
        var flags: Set<String> = []
        /// Transferred per month: "2026-11" → bytes.
        var months: [String: UInt64] = [:]
    }

    private struct Saved: Codable {
        var stats = Stats()
        var unlocked: [String: Date] = [:]
    }

    @Published private(set) var stats: Stats
    @Published private(set) var unlocked: [String: Date]
    private let file: JSONFile<Saved>

    private init(file: JSONFile<Saved> = JSONFile("achievements.json")) {
        self.file = file
        let s = file.load() ?? Saved()
        stats = s.stats
        unlocked = s.unlocked
    }

    // MARK: List

    static var all: [Achievement] { [
        .init(id: "first", title: L("Первый рейс"), detail: L("Перенести первый файл"),
              icon: ["...#....", "...##...", "#######.", "########", "#######.", "...##...", "...#....", "........"]),
        .init(id: "gb1", title: L("Гигабайт"), detail: L("Перенести 1 ГБ"),
              icon: ["........", ".######.", "#......#", "#.####.#", "#......#", ".######.", "..#..#..", "........"]),
        .init(id: "gb100", title: L("100 ГБ без облака"), detail: L("Перенести 100 ГБ по кабелю"),
              icon: ["..####..", ".#....#.", "#......#", "########", "........", "#.#..#.#", ".#....#.", "#.#..#.#"]),
        .init(id: "tb1", title: L("Терабайтник"), detail: L("Перенести 1 ТБ"),
              icon: ["########", "#......#", "#.####.#", "#......#", "########", "#......#", "#.####.#", "########"]),
        .init(id: "photos", title: L("Фотограф"), detail: L("Забрать с камеры 1000 фото и видео"),
              icon: ["..###...", "########", "#..##..#", "#.#..#.#", "#.#..#.#", "#..##..#", "########", "........"]),
        .init(id: "saves", title: L("Хранитель сейвов"), detail: L("Сохранить сейвы Switch на Mac"),
              icon: ["########", "#.####.#", "#.####.#", "#......#", "#.####.#", "#.#..#.#", "#.####.#", "########"]),
        .init(id: "installer", title: L("Установщик"), detail: L("Установить 10 игр или обновлений через DBI"),
              icon: ["...##...", "...##...", "...##...", ".######.", "..####..", "...##...", "#......#", "########"]),
        .init(id: "resumed", title: L("Упрямый"), detail: L("Докачать передачу после обрыва кабеля"),
              icon: ["..####..", ".#....#.", "#......#", "#...#..#", "#....#.#", "#......#", ".#....#.", "..####.#"]),
        .init(id: "night", title: L("Сова"), detail: L("Закончить передачу между полуночью и пятью утра"),
              icon: ["#......#", "##....##", "#.#..#.#", "#.#..#.#", "#..##..#", ".#....#.", "..####..", "...##..."]),
        .init(id: "both", title: L("Два мира"), detail: L("Подключить и телефон, и Switch"),
              icon: ["###..###", "#.#..#.#", "#.#..#.#", "###..###", "........", "#.#..#.#", ".#....#.", "#.#..#.#"]),
        .init(id: "clicker", title: L("Тыкалка"), detail: L("Нажать на маскота 50 раз"),
              icon: ["..#.....", "..#.....", "..###...", "..#.###.", "#.#.#.##", "########", ".######.", "..####.."]),
        .init(id: "konami", title: L("↑↑↓↓←→←→BA"), detail: L("Ввести старый добрый код"),
              icon: ["...#....", "..###...", ".#.#.#..", "...#....", "...#....", ".#.#.#..", "..###...", "...#...."], secret: true),
    ] }

    func isUnlocked(_ a: Achievement) -> Bool { unlocked[a.id] != nil }

    // MARK: Events

    func recordTransfer(bytes: UInt64, label: String?, resumed: Bool, at date: Date = Date()) {
        stats.bytes &+= bytes
        stats.files += 1
        stats.months[Self.monthKey(date), default: 0] &+= bytes
        if let label {
            if label == L("Новое фото") || label == L("Новое видео") || label == L("В «Фото»") { stats.photos += 1 }
            if label == L("Резервная копия") { stats.saves += 1 }
            if label == L("Установка") { stats.installs += 1 }
        }
        if resumed { stats.flags.insert("resumed") }
        let h = Calendar.current.component(.hour, from: date)
        if h < 5 { stats.flags.insert("night") }
        commit()
    }

    func recordDevice(console: Bool) {
        guard stats.kinds.insert(console ? "console" : "phone").inserted else { return }
        commit()
    }

    func recordClick() {
        stats.clicks += 1
        // Write to disk not on every click, only when it changes something.
        if stats.clicks == 50 || stats.clicks % 25 == 0 { commit() }
    }

    func recordKonami() {
        guard stats.flags.insert("konami").inserted else { return }
        commit()
    }

    private func commit() {
        let s = stats
        let checks: [String: Bool] = [
            "first": s.files >= 1, "gb1": s.bytes >= 1_000_000_000, "gb100": s.bytes >= 100_000_000_000,
            "tb1": s.bytes >= 1_000_000_000_000, "photos": s.photos >= 1000, "saves": s.saves >= 1,
            "installer": s.installs >= 10, "resumed": s.flags.contains("resumed"), "night": s.flags.contains("night"),
            "both": s.kinds.isSuperset(of: ["phone", "console"]), "clicker": s.clicks >= 50,
            "konami": s.flags.contains("konami"),
        ]
        var fresh: [Achievement] = []
        for a in Self.all where checks[a.id] == true && unlocked[a.id] == nil {
            unlocked[a.id] = Date()
            fresh.append(a)
        }
        file.save(Saved(stats: stats, unlocked: unlocked))
        // Hand them out one at a time: the mascot's bubble shows the last one.
        if let a = fresh.last { Mascot.shared.react(.achievement(a.title)) }
    }

    // MARK: Stats with humor

    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    var monthBytes: UInt64 { stats.months[Self.monthKey(Date())] ?? 0 }

    /// What it would cost to keep that much in the cloud: iCloud+ tiers by size.
    static func cloudPrice(for bytes: UInt64) -> String {
        switch bytes {
        case 0: "$0"
        case ..<50_000_000_000: "$0.99"
        case ..<200_000_000_000: "$2.99"
        case ..<2_000_000_000_000: "$9.99"
        default: "$29.99"
        }
    }

    /// "This month, past the cloud: 38 GB — cloud storage that size starts at $2.99 a month".
    var monthJoke: String? {
        let b = monthBytes
        guard b > 0 else { return nil }
        return L("За месяц мимо облака: %@. ‖ Подписка на такой объём — от %@ в месяц. Shuttle — $0.",
                 formatBytes(b), Self.cloudPrice(for: b))
    }
}
