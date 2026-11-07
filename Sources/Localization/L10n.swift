import Foundation

/// Язык интерфейса: как в системе, русский или английский.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("Как в системе")
        case .ru: "Русский"
        case .en: "English"
        }
    }
}

/// Строки интерфейса пишутся по-русски; для английского — словарь `English.table`.
enum L10n {
    private(set) static var english: Bool = resolve()

    static func resolve() -> Bool {
        let raw = UserDefaults.standard.string(forKey: "language") ?? ""
        switch AppLanguage(rawValue: raw) ?? .system {
        case .ru: return false
        case .en: return true
        case .system: return !(Locale.preferredLanguages.first ?? "ru").hasPrefix("ru")
        }
    }

    static func reload() { english = resolve() }
}

/// Перевести строку интерфейса.
func L(_ ru: String) -> String {
    guard L10n.english else { return ru }
    return English.table[ru] ?? ru
}

/// Перевести строку с подстановками: L("Свободно %@", size).
func L(_ ru: String, _ args: CVarArg...) -> String {
    String(format: L(ru), locale: Locale.current, arguments: args)
}
