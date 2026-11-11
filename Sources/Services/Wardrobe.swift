import SwiftUI

/// Costumes for Wirrow the mascot. Each badge opens one; holiday hats are open to everyone,
/// and the creator's hat is exclusive.
enum Costume: String, CaseIterable, Identifiable, Codable {
    case none, courier, headphones, pilot, crown, beret, knight, hardhat, bandana, nightcap, viking, propeller, shades, santa, party, creator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L("Как есть")
        case .courier: L("Кепка курьера")
        case .headphones: L("Наушники")
        case .pilot: L("Шлем пилота")
        case .crown: L("Корона")
        case .beret: L("Берет фотографа")
        case .knight: L("Рыцарский шлем")
        case .hardhat: L("Каска")
        case .bandana: L("Бандана")
        case .nightcap: L("Ночной колпак")
        case .viking: L("Шлем викинга")
        case .propeller: L("Кепка с пропеллером")
        case .shades: L("Диско-очки")
        case .santa: L("Новогодний колпак")
        case .party: L("Праздничный колпак")
        case .creator: L("Колпак создателя")
        }
    }

    /// The badge that opens it. nil — open to everyone.
    var badge: String? {
        switch self {
        case .courier: "first"
        case .headphones: "gb1"
        case .pilot: "gb100"
        case .crown: "tb1"
        case .beret: "photos"
        case .knight: "saves"
        case .hardhat: "installer"
        case .bandana: "resumed"
        case .nightcap: "night"
        case .viking: "both"
        case .propeller: "clicker"
        case .shades: "konami"
        case .none, .santa, .party, .creator: nil
        }
    }

    var exclusive: Bool { self == .creator }

    /// Hats sit where the antennas are; glasses and a bandana leave them in place.
    var hidesAntennas: Bool { ![.none, .shades, .bandana].contains(self) }
}

/// What the mascot wears. "As is" — holiday hats by the date, like before.
@MainActor
final class Wardrobe: ObservableObject {
    static let shared = Wardrobe()

    @Published private(set) var selected: Costume
    private let d = AppSettings.defaults

    private init() {
        selected = Costume(rawValue: d.string(forKey: "costume") ?? "") ?? .none
        if !isUnlocked(selected) { selected = .none }
    }

    /// The whole wardrobe and the exclusive costume, given by the author:
    /// `defaults write com.vadimgrekov.shuttle wardrobe.vip -bool true`.
    var vip: Bool { d.bool(forKey: "wardrobe.vip") }

    /// Costumes shown in Settings: the exclusive one only for those who have it.
    var visible: [Costume] { Costume.allCases.filter { !$0.exclusive || vip } }

    func isUnlocked(_ c: Costume) -> Bool {
        if vip { return true }
        if c.exclusive { return false }
        guard let id = c.badge else { return true }
        return Achievements.shared.unlocked[id] != nil
    }

    /// The badge title that opens the costume, for the hint on a locked tile.
    func badgeTitle(_ c: Costume) -> String? {
        guard let id = c.badge else { return nil }
        return Achievements.all.first { $0.id == id }?.title
    }

    func select(_ c: Costume) {
        guard isUnlocked(c), c != selected else { return }
        selected = c
        d.set(c.rawValue, forKey: "costume")
        Mascot.shared.wear(c)
    }

    /// What to draw right now: the chosen costume, or a holiday hat by the date.
    func current(at date: Date = Date()) -> Costume {
        selected == .none ? Mascot.hat(at: date) : selected
    }
}
