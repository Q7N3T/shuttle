import Foundation

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

    /// Иконка по названию раздела (DBI на Switch отдаёт 9 разделов).
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
    /// Чтобы помнить устройство между подключениями (избранное, синхронизация, импорт).
    var serial: String = ""
    var transport: Transport = .mtp

    // Первый раздел — для мест, где важна «основная» память.
    var storageID: UInt32 { storages[0].id }
    var storageName: String { storages[0].name }
    var capacity: UInt64 { storages[0].capacity }
    var free: UInt64 { storages[0].free }

    /// Ключ для настроек, привязанных к устройству.
    var key: String { serial.isEmpty ? name : serial }

    func storage(where match: (StorageInfo) -> Bool) -> StorageInfo? { storages.first(where: match) }
}

enum MTPError: LocalizedError, Equatable {
    case notConnected
    case busy
    case locked
    case cancelled
    /// Кабель отошёл посреди передачи — передачу можно продолжить.
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

/// Флаг отмены, который читается с очереди устройства и пишется с главного потока.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

func localSize(_ url: URL) -> UInt64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        return UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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

/// «Фото.jpg» → «Фото 2.jpg», если такое имя уже занято.
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
