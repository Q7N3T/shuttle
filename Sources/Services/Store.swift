import Foundation
import SwiftUI

/// The app's data folder: ~/Library/Application Support/Wirrow.
enum AppFolders {
    /// The app's name before 0.6.0. Only used to carry old data over to the new folders.
    static let legacyName = "Shuttle"

    /// One time: move Application Support and Documents folders from the old name to the new one.
    private static let migrated: Void = {
        guard !testing else { return }
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory] {
            let base = fm.urls(for: dir, in: .userDomainMask)[0]
            let old = base.appendingPathComponent(legacyName, isDirectory: true)
            let new = base.appendingPathComponent("Wirrow", isDirectory: true)
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        }
    }()

    static var support: URL {
        _ = migrated
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent(testing ? "Wirrow-Tests" : "Wirrow", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Wirrow", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Automated tests are running — don't touch real data.
    static var testing: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    static func documents(_ sub: String) -> URL {
        _ = migrated
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wirrow", isDirectory: true).appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Simple storage of a Codable value in a JSON file.
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

/// Settings changed in the ⌘, window and in the menu.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    /// Automated tests write to their own settings, not the user's real ones.
    static let defaults: UserDefaults = AppFolders.testing ? UserDefaults(suiteName: "com.vadimgrekov.shuttle.tests")! : .standard
    private let d = AppSettings.defaults

    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    @Published var heicToJPEG: Bool { didSet { d.set(heicToJPEG, forKey: "heicToJPEG") } }
    @Published var menuBarIcon: Bool { didSet { d.set(menuBarIcon, forKey: "menuBarIcon") } }
    /// The mascot in the header comments on connections and transfers by itself.
    @Published var mascotTalks: Bool { didSet { d.set(mascotTalks, forKey: "mascotTalks") } }
    /// Without a window: Wirrow lives in the menu bar, transfers and auto-import keep going.
    @Published var menuBarMode: Bool { didSet { d.set(menuBarMode, forKey: "menuBarMode") } }
    /// Import new photos automatically when the phone connects.
    @Published var autoImport: Bool { didSet { d.set(autoImport, forKey: "autoImport") } }
    @Published var adbEnabled: Bool {
        didSet { d.set(adbEnabled, forKey: "adbEnabled"); DeviceHub.shared.reload() }
    }
    @Published var autoSync: Bool { didSet { d.set(autoSync, forKey: "autoSync") } }
    @Published var thumbnails: Bool { didSet { d.set(thumbnails, forKey: "thumbnails") } }
    @Published var language: AppLanguage { didSet { d.set(language.rawValue, forKey: "language"); L10n.reload() } }
    @Published var photosFolder: URL {
        didSet { d.set(photosFolder.path, forKey: "photosFolder") }
    }

    private init() {
        d.register(defaults: ["notifications": true, "thumbnails": true, "menuBarIcon": false, "mascotTalks": true])
        notifications = d.bool(forKey: "notifications")
        heicToJPEG = d.bool(forKey: "heicToJPEG")
        menuBarIcon = d.bool(forKey: "menuBarIcon")
        mascotTalks = d.bool(forKey: "mascotTalks")
        menuBarMode = d.bool(forKey: "menuBarMode")
        autoImport = d.bool(forKey: "autoImport")
        adbEnabled = d.bool(forKey: "adbEnabled")
        autoSync = d.bool(forKey: "autoSync")
        thumbnails = d.bool(forKey: "thumbnails")
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        let picsBase = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        // Photos already imported under the old name stay where they are: sync pairs and the import log point there.
        let legacyPics = picsBase.appendingPathComponent(AppFolders.legacyName, isDirectory: true)
        let pics = FileManager.default.fileExists(atPath: legacyPics.path) ? legacyPics : picsBase.appendingPathComponent("Wirrow", isDirectory: true)
        photosFolder = d.string(forKey: "photosFolder").map { URL(fileURLWithPath: $0) } ?? pics
    }
}
