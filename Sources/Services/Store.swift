import Foundation
import SwiftUI

/// Папка данных приложения: ~/Library/Application Support/Shuttle.
enum AppFolders {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent(testing ? "Shuttle-Tests" : "Shuttle", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Shuttle", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Запущены автотесты — не трогаем настоящие данные.
    static var testing: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    static func documents(_ sub: String) -> URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shuttle", isDirectory: true).appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Простое хранение Codable-значения в JSON-файле.
struct JSONFile<T: Codable> {
    let url: URL
    init(_ name: String, in dir: URL = AppFolders.support) { url = dir.appendingPathComponent(name) }

    func load() -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }

    func save(_ value: T) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(value) { try? d.write(to: url, options: .atomic) }
    }
}

/// Настройки, которые меняются в окне ⌘, и в меню.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    /// Автотесты пишут в свои настройки, а не в настоящие настройки пользователя.
    static let defaults: UserDefaults = AppFolders.testing ? UserDefaults(suiteName: "com.vadimgrekov.shuttle.tests")! : .standard
    private let d = AppSettings.defaults

    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    @Published var heicToJPEG: Bool { didSet { d.set(heicToJPEG, forKey: "heicToJPEG") } }
    @Published var menuBarIcon: Bool { didSet { d.set(menuBarIcon, forKey: "menuBarIcon") } }
    @Published var adbEnabled: Bool {
        didSet { d.set(adbEnabled, forKey: "adbEnabled"); DeviceService.shared.reloadDrivers() }
    }
    @Published var autoSync: Bool { didSet { d.set(autoSync, forKey: "autoSync") } }
    @Published var thumbnails: Bool { didSet { d.set(thumbnails, forKey: "thumbnails") } }
    @Published var language: AppLanguage { didSet { d.set(language.rawValue, forKey: "language"); L10n.reload() } }
    @Published var photosFolder: URL {
        didSet { d.set(photosFolder.path, forKey: "photosFolder") }
    }

    private init() {
        d.register(defaults: ["notifications": true, "thumbnails": true, "menuBarIcon": false])
        notifications = d.bool(forKey: "notifications")
        heicToJPEG = d.bool(forKey: "heicToJPEG")
        menuBarIcon = d.bool(forKey: "menuBarIcon")
        adbEnabled = d.bool(forKey: "adbEnabled")
        autoSync = d.bool(forKey: "autoSync")
        thumbnails = d.bool(forKey: "thumbnails")
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shuttle", isDirectory: true)
        photosFolder = d.string(forKey: "photosFolder").map { URL(fileURLWithPath: $0) } ?? pics
    }
}
