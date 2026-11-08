import Foundation
import CryptoKit

let mtpRoot: UInt32 = 0xFFFF_FFFF

struct RemoteItem: Identifiable, Hashable {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let size: UInt64
    let modified: Date
    let isFolder: Bool
}

struct StorageInfo: Equatable, Identifiable, Hashable {
    let id: UInt32
    let name: String
    let capacity: UInt64
    let free: UInt64

    /// An icon by storage name (DBI on a Switch exposes 9 storages).
    var icon: String {
        let n = name.lowercased()
        if n.contains("installed") { return "gamecontroller" }
        if n.contains("install") { return "square.and.arrow.down" }
        if n.contains("save") { return "tray.full" }
        if n.contains("album") { return "photo.on.rectangle" }
        if n.contains("gamecard") || n.contains("cartridge") { return "memorychip" }
        if n.contains("sd") { return "sdcard" }
        return "internaldrive"
    }

    var isInstallTarget: Bool { name.lowercased().contains("install") && !name.lowercased().contains("installed") }
    var isSaves: Bool { name.lowercased().contains("save") }
    var isAlbum: Bool { name.lowercased().contains("album") }
    var isInstalledGames: Bool { name.lowercased().contains("installed") }
    var isSDCard: Bool { name.lowercased() == "sd card" }
}

enum DeviceKind: Equatable {
    case phone, console
}

enum Transport: String, Equatable {
    case mtp = "MTP", adb = "ADB", mock = "Тест"
}

struct DeviceInfo: Equatable {
    var name: String
    var kind: DeviceKind
    var storages: [StorageInfo]
    var battery: Int?
    /// Remembers the device between connections (favorites, sync, import).
    var serial: String = ""
    var transport: Transport = .mtp

    // The first storage — for places where the "main" memory matters.
    var storageID: UInt32 { storages[0].id }
    var storageName: String { storages[0].name }
    var capacity: UInt64 { storages[0].capacity }
    var free: UInt64 { storages[0].free }

    /// The key for per-device settings.
    var key: String { serial.isEmpty ? name : serial }

    func storage(where match: (StorageInfo) -> Bool) -> StorageInfo? { storages.first(where: match) }
}

enum MTPError: LocalizedError, Equatable {
    case notConnected
    case busy
    case locked
    case cancelled
    /// The cable came out mid-transfer — the transfer can be resumed.
    case interrupted
    case noSpace(needed: UInt64, free: UInt64)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: L("Устройство не подключено")
        case .busy: L("Устройство занято другой программой. Закройте «Захват изображений», «Фото» и Android File Transfer.")
        case .locked: L("Разблокируйте телефон и выберите в уведомлении USB режим «Передача файлов».")
        case .cancelled: L("Отменено")
        case .interrupted: L("Связь прервалась — продолжим, когда устройство вернётся")
        case .noSpace(let n, let f): L("Не хватает места: нужно %@, свободно %@", formatBytes(n), formatBytes(f))
        case .failed(let m): m
        }
    }
}

/// A cancel flag read from the device queue and written from the main thread.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var checked = 0
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    /// How many files of this transfer were verified after copying.
    var verified: Int { lock.lock(); defer { lock.unlock() }; return checked }
    func noteVerified() { lock.lock(); checked += 1; lock.unlock() }
}

func localSize(_ url: URL) -> UInt64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        // Not resourceValues: URL caches the size, and after appending to the file we'd get the old one.
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }
    var sum: UInt64 = 0
    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                              options: [.skipsHiddenFiles]) {
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { sum += UInt64(v?.fileSize ?? 0) }
        }
    }
    return sum
}

/// "Photo.jpg" → "Photo 2.jpg" if that name is taken.
func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url }
    let dir = url.deletingLastPathComponent()
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    var n = 2
    while true {
        let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        let candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        n += 1
    }
}

/// SHA-256 of a file on the Mac, read in 1 MB chunks.
func sha256Hex(of url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
