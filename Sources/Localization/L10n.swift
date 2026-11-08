import Foundation

/// Interface language: system, Russian or English.
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

/// Interface strings are written in Russian; English comes from the `English.table` dictionary.
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

/// Translate an interface string.
func L(_ ru: String) -> String {
    guard L10n.english else { return ru }
    return English.table[ru] ?? ru
}

/// Translate a string with arguments: L("Свободно %@", size).
func L(_ ru: String, _ args: CVarArg...) -> String {
    String(format: L(ru), locale: Locale.current, arguments: args)
}
