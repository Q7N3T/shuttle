import Foundation

/// Android через ADB: быстрее MTP, работает по Wi‑Fi, умеет ставить APK и снимать экран.
/// Нужен установленный `adb` (Android platform-tools) и включённая отладка на телефоне.
final class ADBDriver: DeviceDriver {
    let transport: Transport = .adb
    private var serial: String?
    private var pathByID: [UInt32: String] = [mtpRoot: ADBDriver.root]
    private var idByPath: [String: UInt32] = [ADBDriver.root: mtpRoot]
    private var nextID: UInt32 = 1
    static let root = "/sdcard"

    /// Где искать adb: Homebrew, Android Studio, PATH.
    static var executable: String? {
        let fm = FileManager.default
        var paths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                     NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
        if let p = ProcessInfo.processInfo.environment["PATH"] {
            paths += p.split(separator: ":").map { "\($0)/adb" }
        }
        return paths.first { fm.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { executable != nil }

    // MARK: Запуск adb

    @discardableResult
    static func adb(_ args: [String], serial: String? = nil, timeout: TimeInterval = 30) throws -> Data {
        guard let exe = executable else { throw MTPError.failed(L("adb не найден. Установите Android platform-tools.")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = (serial.map { ["-s", $0] } ?? []) + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        var data = Data()
        let reader = DispatchQueue(label: "adb.read")
        let group = DispatchGroup()
        group.enter()
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw MTPError.failed(L("adb не отвечает"))
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MTPError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? L("Ошибка adb") : msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    private func shell(_ command: String, timeout: TimeInterval = 30) throws -> String {
        let d = try ADBDriver.adb(["shell", command], serial: serial, timeout: timeout)
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Подключиться по Wi‑Fi: `adb connect 192.168.1.20:5555`.
    static func connectWiFi(_ address: String) throws -> String {
        let d = try adb(["connect", address], timeout: 15)
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: DeviceDriver

    func connectIfNeeded() throws -> DeviceInfo {
        guard ADBDriver.isAvailable else { throw MTPError.notConnected }
        let text = String(data: try ADBDriver.adb(["devices", "-l"], timeout: 8), encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n").dropFirst().map(String.init).filter { !$0.isEmpty }
        guard let line = lines.first(where: { $0.contains(" device ") || $0.hasSuffix(" device") })
                ?? lines.first(where: { $0.contains("unauthorized") }) else {
            serial = nil
            throw MTPError.notConnected
        }
        if line.contains("unauthorized") {
            throw MTPError.locked
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        serial = parts.first
        let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }?
            .replacingOccurrences(of: "_", with: " ") ?? "Android"

        var battery: Int?
        if let b = try? shell("dumpsys battery | grep level", timeout: 5),
           let v = Int(b.filter(\.isNumber)) { battery = v }

        var capacity: UInt64 = 0, free: UInt64 = 0
        if let df = try? shell("df -k \(ADBDriver.root) | tail -1", timeout: 5) {
            let f = df.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 4, let total = UInt64(f[1]), let avail = UInt64(f[3]) {
                capacity = total * 1024
                free = avail * 1024
            }
        }
        return DeviceInfo(name: model, kind: .phone,
                          storages: [StorageInfo(id: 1, name: L("Внутренняя память"), capacity: capacity, free: free)],
                          battery: battery, serial: serial ?? "", transport: .adb)
    }

    func release() { serial = nil }

    private func path(_ id: UInt32) throws -> String {
        guard let p = pathByID[id == 0 ? mtpRoot : id] else { throw MTPError.failed(L("Папка больше не существует")) }
        return p
    }

    private func id(for path: String) -> UInt32 {
        if let id = idByPath[path] { return id }
        nextID += 1
        idByPath[path] = nextID
        pathByID[nextID] = path
        return nextID
    }

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem] {
        let dir = try path(parent)
        // toybox: тип|размер|время|путь для каждого элемента папки
        let out = try shell("find \(ADBDriver.quote(dir)) -mindepth 1 -maxdepth 1 -exec stat -c '%F|%s|%Y|%n' {} + 2>/dev/null")
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard f.count == 4 else { return nil }
            let full = f[3]
            return RemoteItem(id: id(for: full), parentID: parent == mtpRoot ? 0 : parent, storageID: storage,
                              name: (full as NSString).lastPathComponent, size: UInt64(f[1]) ?? 0,
                              modified: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0),
                              isFolder: f[0].contains("directory"))
        }
    }

    // MARK: Сверка: по ADB телефон сам считает размер и SHA-256

    func remoteSize(_ id: UInt32) -> UInt64? {
        guard let p = try? path(id), let out = try? shell("stat -c %s \(ADBDriver.quote(p))") else { return nil }
        return UInt64(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func sha256(_ item: RemoteItem) -> String? {
        guard let p = try? path(item.id), let out = try? shell("sha256sum \(ADBDriver.quote(p))", timeout: 300) else { return nil }
        let hex = out.split(separator: " ").first.map(String.init) ?? ""
        return hex.count == 64 ? hex : nil
    }

    func download(_ item: RemoteItem, to url: URL, offset: UInt64,
                  progress: @escaping (UInt64, UInt64) -> Bool) throws {
        let remote = try path(item.id)
        try runWatching(["pull", remote, url.path], total: item.size,
                        measure: { localSize(url) }, progress: progress)
    }

    @discardableResult
    func upload(_ url: URL, parent: UInt32, storage: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        let dir = try path(parent)
        let remote = (dir as NSString).appendingPathComponent(url.lastPathComponent)
        let total = localSize(url)
        try runWatching(["push", url.path, remote], total: total, measure: { [weak self] in
            guard let s = try? self?.shell("stat -c %s \(ADBDriver.quote(remote)) 2>/dev/null", timeout: 3) else { return 0 }
            return UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }, progress: progress)
        return id(for: remote)
    }

    /// adb не отдаёт прогресс без терминала — меряем размер сами, пока идёт копирование.
    private func runWatching(_ args: [String], total: UInt64, measure: @escaping () -> UInt64,
                             progress: @escaping (UInt64, UInt64) -> Bool) throws {
        guard let exe = ADBDriver.executable else { throw MTPError.notConnected }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = (serial.map { ["-s", $0] } ?? []) + args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        while p.isRunning {
            Thread.sleep(forTimeInterval: 0.3)
            if !progress(min(measure(), total), total) {
                p.terminate()
                throw MTPError.cancelled
            }
        }
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if (try? ADBDriver.adb(["get-state"], serial: serial, timeout: 3)) == nil { throw MTPError.interrupted }
            throw MTPError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = progress(total, total)
    }

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32 {
        let p = ((try path(parent)) as NSString).appendingPathComponent(name)
        _ = try shell("mkdir -p \(ADBDriver.quote(p))")
        return id(for: p)
    }

    func delete(_ id: UInt32) throws {
        _ = try shell("rm -rf \(ADBDriver.quote(try path(id)))")
    }

    func rename(_ id: UInt32, to name: String) throws {
        let old = try path(id)
        let new = ((old as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        _ = try shell("mv \(ADBDriver.quote(old)) \(ADBDriver.quote(new))")
        // Переносим и пути вложенных объектов, которые уже видели.
        for (cid, p) in pathByID where p == old || p.hasPrefix(old + "/") {
            let moved = new + p.dropFirst(old.count)
            pathByID[cid] = moved
            idByPath[p] = nil
            idByPath[moved] = cid
        }
    }

    // MARK: Только ADB

    func install(apk url: URL) throws {
        _ = try ADBDriver.adb(["install", "-r", url.path], serial: serial, timeout: 300)
    }

    func screenshot() throws -> Data {
        try ADBDriver.adb(["exec-out", "screencap", "-p"], serial: serial, timeout: 20)
    }
}
