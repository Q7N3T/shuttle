import Foundation
import IOKit
import IOKit.usb

// MARK: - Имена игр DBI

/// «Mario Kart 8 Deluxe [0100152000022000][v0]» → название, ID и версия.
struct GameName: Equatable {
    let title: String
    let titleID: String?
    let version: String?

    init(_ raw: String) {
        let name = (raw as NSString).pathExtension.lowercased() == "nca" ? (raw as NSString).deletingPathExtension : raw
        let pattern = #"\[([0-9A-Fa-f]{16})\]"#
        let idRange = name.range(of: pattern, options: .regularExpression)
        titleID = idRange.map { String(name[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).uppercased() }
        let ver = name.range(of: #"\[v(\d+)\]"#, options: .regularExpression)
        version = ver.map { String(name[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        var t = name
        if let r = idRange { t = String(name[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        title = t.isEmpty ? name : t
    }

    var hasID: Bool { titleID != nil }
}

// MARK: - Установка игр

enum GameFiles {
    static let installable: Set<String> = ["nsp", "nsz", "xci", "xcz"]
    static func isInstallable(_ url: URL) -> Bool { installable.contains(url.pathExtension.lowercased()) }
}

// MARK: - Homebrew из архива

/// Раскладывает распакованный архив homebrew по папкам SD-карты.
enum HomebrewLayout {
    /// Папки, которые лежат в корне SD-карты.
    static let rootFolders: Set<String> = ["atmosphere", "bootloader", "switch", "config", "emummc",
                                           "warmboot_mariko", "nintendo", "themes", "tinfoil", "jksv", "retroarch"]

    struct Placement: Equatable {
        let local: URL
        /// Куда положить на SD: путь из папок (файл попадает внутрь).
        let remoteFolder: [String]
    }

    static func plan(unpacked root: URL) -> [Placement] {
        let fm = FileManager.default
        var top = visible(root)
        // Архив с единственной обёрткой «SomeTool-1.2/…» — заходим внутрь.
        while top.count == 1, isDir(top[0]), !rootFolders.contains(top[0].lastPathComponent.lowercased()) {
            let inner = visible(top[0])
            if inner.isEmpty { break }
            top = inner
        }
        var out: [Placement] = []
        for u in top {
            let name = u.lastPathComponent
            let lower = name.lowercased()
            if isDir(u), rootFolders.contains(lower) {
                out.append(Placement(local: u, remoteFolder: []))
            } else if !isDir(u) {
                switch u.pathExtension.lowercased() {
                case "nro":
                    out.append(Placement(local: u, remoteFolder: ["switch", u.deletingPathExtension().lastPathComponent]))
                case "ovl":
                    out.append(Placement(local: u, remoteFolder: ["switch", ".overlays"]))
                case "bin" where lower.contains("fusee") || lower.contains("hekate") || lower.contains("payload"):
                    out.append(Placement(local: u, remoteFolder: ["bootloader", "payloads"]))
                default:
                    out.append(Placement(local: u, remoteFolder: []))
                }
            } else {
                // Незнакомая папка: если внутри .nro — это приложение для /switch.
                let hasNRO = (fm.enumerator(at: u, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .contains { $0.pathExtension.lowercased() == "nro" }
                out.append(Placement(local: u, remoteFolder: hasNRO ? ["switch"] : []))
            }
        }
        return out
    }

    /// Распаковать zip штатным ditto во временную папку.
    static func unzip(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Shuttle-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw MTPError.failed(L("Не удалось распаковать %@", zip.lastPathComponent)) }
        // Мусор macOS из архивов.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("__MACOSX"))
        return dir
    }

    private static func visible(_ u: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }
}

// MARK: - Atmosphère

struct AtmosphereRelease: Equatable {
    let version: String
    let published: Date?
    let zipURL: URL
    let fuseeURL: URL?
    let notesURL: URL
}

enum Atmosphere {
    static let api = URL(string: "https://api.github.com/repos/Atmosphere-NX/Atmosphere/releases/latest")!

    static func parse(_ json: Data) throws -> AtmosphereRelease {
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { throw MTPError.failed(L("Не удалось прочитать релиз Atmosphère")) }
        func asset(_ match: (String) -> Bool) -> URL? {
            assets.first { match(($0["name"] as? String ?? "").lowercased()) }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let zip = asset({ $0.hasPrefix("atmosphere") && $0.hasSuffix(".zip") }) else {
            throw MTPError.failed(L("В релизе Atmosphère нет архива"))
        }
        let date = (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? api
        return AtmosphereRelease(version: tag, published: date, zipURL: zip,
                                 fuseeURL: asset { $0 == "fusee.bin" }, notesURL: page)
    }

    static func latest() async throws -> AtmosphereRelease {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Shuttle", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw MTPError.failed(L("GitHub ответил %d. Попробуйте позже.", h.statusCode))
        }
        return try parse(data)
    }

    static func download(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw MTPError.failed(L("Не удалось скачать %@", url.lastPathComponent)) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

// MARK: - USB: Switch подключена, но DBI не запущен

enum USBProbe {
    /// Есть ли по USB устройство Nintendo (0x057E) — даже если MTP не включён.
    static func nintendoPresent() -> Bool {
        guard let match = IOServiceMatching("IOUSBHostDevice") else { return false }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }
        while case let dev = IOIteratorNext(iter), dev != 0 {
            defer { IOObjectRelease(dev) }
            if let v = IORegistryEntryCreateCFProperty(dev, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int, v == 0x057E {
                return true
            }
        }
        return false
    }
}
