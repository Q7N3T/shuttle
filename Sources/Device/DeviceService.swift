import Foundation

/// Что делать, если на устройстве уже есть файл с таким именем.
enum ConflictPolicy {
    /// Тот же размер — пропустить (так работает и продолжение после обрыва).
    case skipIdentical
    /// Удалить старый и загрузить заново (обновление homebrew, Atmosphère).
    case replace
}

/// Вся работа с устройством идёт через одну последовательную очередь:
/// libmtp не потокобезопасна, а MTP умеет только одну операцию за раз.
/// Над драйвером (MTP / ADB / тестовый) — общие операции с деревьями папок.
final class DeviceService: @unchecked Sendable {
    static let shared = DeviceService()

    private let queue = DispatchQueue(label: "shuttle.device", qos: .userInitiated)
    private var candidates: [DeviceDriver]
    private(set) var active: DeviceDriver?
    /// Файлы, загрузка которых оборвалась: их остаток на устройстве можно удалить.
    private var partialUploads: Set<String> = []

    init(drivers: [DeviceDriver]? = nil) {
        candidates = drivers ?? DeviceService.defaultDrivers()
    }

    static func defaultDrivers() -> [DeviceDriver] {
        #if DEBUG
        if let kind = MockDriver.requestedKind { return [MockDriver(kind: kind)] }
        #endif
        var list: [DeviceDriver] = []
        if UserDefaults.standard.bool(forKey: "adbEnabled") { list.append(ADBDriver()) }
        list.append(MTPDriver())
        return list
    }

    /// Пересобрать список драйверов (включили/выключили ADB в настройках).
    func reloadDrivers() {
        queue.async {
            self.active?.release()
            self.active = nil
            self.candidates = DeviceService.defaultDrivers()
        }
    }

    // MARK: Очередь

    func run<T>(_ work: @escaping (DeviceService) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work(self)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Для колбэков AppKit (перетаскивание в Finder).
    func runDetached(_ work: @escaping (DeviceService) -> Void) {
        queue.async { work(self) }
    }

    /// Для тестов: выполнить синхронно на очереди.
    func sync<T>(_ work: (DeviceService) throws -> T) rethrows -> T {
        try queue.sync { try work(self) }
    }

    private func driver() throws -> DeviceDriver {
        guard let active else { throw MTPError.notConnected }
        return active
    }

    // MARK: Подключение

    func connectIfNeeded() throws -> DeviceInfo {
        if let a = active {
            do { return try a.connectIfNeeded() } catch MTPError.notConnected { active = nil }
        }
        var lastError: Error = MTPError.notConnected
        for d in candidates {
            do {
                let info = try d.connectIfNeeded()
                active = d
                return info
            } catch MTPError.notConnected {
                continue
            } catch {
                // Устройство есть, но занято или заблокировано — дальше не ищем.
                active = d
                lastError = error
                break
            }
        }
        throw lastError
    }

    func heartbeat() throws -> DeviceInfo { try connectIfNeeded() }

    func release() {
        active?.release()
        active = nil
    }

    // MARK: Файлы

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem] {
        try driver().list(storage: storage, parent: parent).sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Найти папку по пути из имён, например ["DCIM", "Camera"].
    func resolve(path: [String], storage: UInt32) throws -> [(id: UInt32, name: String)] {
        var parent = mtpRoot
        var crumbs: [(UInt32, String)] = []
        for name in path {
            let items = try list(storage: storage, parent: parent)
            guard let f = items.first(where: { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw MTPError.failed(L("Папка «%@» не найдена", path.joined(separator: "/")))
            }
            parent = f.id
            crumbs.append((f.id, f.name))
        }
        return crumbs
    }

    /// Папка с таким именем или новая. Путь создаётся целиком: ["switch", "DBI"].
    func ensureFolder(path: [String], storage: UInt32, from root: UInt32 = mtpRoot) throws -> UInt32 {
        var parent = root
        for name in path where !name.isEmpty {
            let items = try list(storage: storage, parent: parent)
            if let f = items.first(where: { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                parent = f.id
            } else {
                parent = try driver().createFolder(name, parent: parent, storage: storage)
            }
        }
        return parent
    }

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32 {
        try driver().createFolder(name, parent: parent, storage: storage)
    }

    func delete(_ id: UInt32) throws { try driver().delete(id) }
    func rename(_ id: UInt32, to name: String) throws { try driver().rename(id, to: name) }
    func thumbnail(_ item: RemoteItem) -> Data? { active?.thumbnail(item) }

    @discardableResult
    func upload(_ url: URL, parent: UInt32, storage: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        try driver().upload(url, parent: parent, storage: storage, progress: progress)
    }

    /// MTP не всегда удаляет непустые папки, поэтому идём снизу вверх.
    func deleteTree(_ item: RemoteItem) throws {
        if item.isFolder {
            for c in try list(storage: item.storageID, parent: item.id) { try deleteTree(c) }
        }
        try driver().delete(item.id)
    }

    // MARK: Деревья

    /// Все файлы внутри папки с путями относительно неё.
    func walk(storage: UInt32, root: UInt32, token: CancelToken? = nil, maxDepth: Int = 24,
              visit: ((String) -> Void)? = nil) throws -> [(item: RemoteItem, path: [String])] {
        var out: [(RemoteItem, [String])] = []
        func go(_ parent: UInt32, _ prefix: [String], _ depth: Int) throws {
            if token?.isCancelled == true { throw MTPError.cancelled }
            visit?(prefix.joined(separator: "/"))
            for it in try list(storage: storage, parent: parent) {
                let p = prefix + [it.name]
                if it.isFolder {
                    if depth < maxDepth { try go(it.id, p, depth + 1) }
                } else {
                    out.append((it, p))
                }
            }
        }
        try go(root, [], 0)
        return out
    }

    /// Поиск по имени внутри папки и всех вложенных. Находки отдаются по мере обхода.
    func search(storage: UInt32, root: UInt32, query: String, token: CancelToken,
                found: @escaping (RemoteItem, [String]) -> Void, scanned: @escaping (Int) -> Void) throws {
        let q = query.lowercased()
        var count = 0
        func go(_ parent: UInt32, _ prefix: [String], _ depth: Int) throws {
            if token.isCancelled { throw MTPError.cancelled }
            for it in try list(storage: storage, parent: parent) {
                count += 1
                if it.name.lowercased().contains(q) { found(it, prefix) }
                if it.isFolder, depth < 16 { try go(it.id, prefix + [it.name], depth + 1) }
            }
            scanned(count)
        }
        try go(root, [], 0)
    }

    /// Скачать файл или папку целиком.
    /// `resumeInto` — продолжить в уже начатое место: готовые файлы пропускаются, недокачанные докачиваются.
    func downloadTree(_ item: RemoteItem, into dir: URL, token: CancelToken, resumeInto: URL? = nil,
                      progress: @escaping (UInt64, UInt64) -> Void) throws -> URL {
        let d = try driver()
        let fm = FileManager.default
        var plan: [(RemoteItem, URL)] = []
        func walk(_ it: RemoteItem, _ dest: URL) throws {
            if token.isCancelled { throw MTPError.cancelled }
            if it.isFolder {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for c in try list(storage: it.storageID, parent: it.id) {
                    try walk(c, dest.appendingPathComponent(c.name))
                }
            } else {
                plan.append((it, dest))
            }
        }
        let target = resumeInto ?? uniqueURL(dir.appendingPathComponent(item.name))
        try walk(item, target)

        let total = plan.reduce(UInt64(0)) { $0 + $1.0.size }
        var done: UInt64 = 0
        progress(0, total)
        for (it, dest) in plan {
            if token.isCancelled { throw MTPError.cancelled }
            let have = resumeInto != nil ? localSize(dest) : 0
            if resumeInto != nil, have == it.size, fm.fileExists(atPath: dest.path) {
                done += it.size
                progress(done, total)
                continue
            }
            let offset = (have > 0 && have < it.size && d.supportsPartialDownload) ? have : 0
            if offset == 0 { try? fm.removeItem(at: dest) }
            let base = done
            do {
                try d.download(it, to: dest, offset: offset) { sent, _ in
                    progress(base + sent, total)
                    return !token.isCancelled
                }
            } catch MTPError.interrupted {
                // Обрыв: недокачанное оставляем — продолжим с этого места.
                throw MTPError.interrupted
            } catch {
                // Отмена или ошибка: обрывок не нужен.
                try? fm.removeItem(at: dest)
                throw error
            }
            done += it.size
        }
        progress(total, total)
        return target
    }

    /// Загрузить файлы и папки. Папки сливаются с существующими.
    func uploadTree(_ urls: [URL], parent: UInt32, storage: UInt32, token: CancelToken,
                    conflict: ConflictPolicy = .skipIdentical,
                    progress: @escaping (UInt64, UInt64) -> Void) throws {
        let d = try driver()
        let fm = FileManager.default
        let total = urls.reduce(UInt64(0)) { $0 + localSize($1) }
        var done: UInt64 = 0
        progress(0, total)

        func send(_ url: URL, parent: UInt32) throws {
            if token.isCancelled { throw MTPError.cancelled }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let existing = try list(storage: storage, parent: parent)
            let name = url.lastPathComponent
            if isDir.boolValue {
                let folderID = try existing.first(where: { $0.isFolder && $0.name == name })?.id
                    ?? d.createFolder(name, parent: parent, storage: storage)
                let kids = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])
                for k in kids { try send(k, parent: folderID) }
                return
            }
            let size = localSize(url)
            let key = "\(storage)/\(parent)/\(name)"
            if let old = existing.first(where: { !$0.isFolder && $0.name == name }) {
                if conflict == .skipIdentical, old.size == size, !partialUploads.contains(key) {
                    done += size
                    progress(done, total)
                    return
                }
                // Замена, или остаток оборванной загрузки.
                if conflict == .replace || partialUploads.contains(key) { try d.delete(old.id) }
            }
            let base = done
            partialUploads.insert(key)
            do {
                try d.upload(url, parent: parent, storage: storage) { sent, _ in
                    progress(base + sent, total)
                    return !token.isCancelled
                }
                partialUploads.remove(key)
            } catch MTPError.interrupted {
                throw MTPError.interrupted
            } catch {
                partialUploads.remove(key)
                throw error
            }
            done += size
        }
        for u in urls { try send(u, parent: parent) }
        progress(total, total)
    }
}
