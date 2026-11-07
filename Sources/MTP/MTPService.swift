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
}

enum DeviceKind: Equatable {
    case phone, console
}

struct DeviceInfo: Equatable {
    var name: String
    var kind: DeviceKind
    var storages: [StorageInfo]
    var battery: Int?

    // Первый раздел — для мест, где важна «основная» память.
    var storageID: UInt32 { storages[0].id }
    var storageName: String { storages[0].name }
    var capacity: UInt64 { storages[0].capacity }
    var free: UInt64 { storages[0].free }
}

enum MTPError: LocalizedError, Equatable {
    case notConnected
    case busy
    case locked
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Телефон не подключён"
        case .busy: "Телефон занят другой программой. Закройте «Захват изображений», «Фото» и Android File Transfer."
        case .locked: "Разблокируйте телефон и выберите в уведомлении USB режим «Передача файлов»."
        case .cancelled: "Отменено"
        case .failed(let m): m
        }
    }
}

/// Флаг отмены, который читается с очереди MTP и пишется с главного потока.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

private final class ProgressBox {
    let handler: (UInt64, UInt64) -> Bool
    var cancelled = false
    init(_ handler: @escaping (UInt64, UInt64) -> Bool) { self.handler = handler }
}

private let progressThunk: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    // MTP считает в отправленном и служебный заголовок, поэтому обрезаем по размеру.
    if box.handler(min(sent, total), total) { return 0 }
    box.cancelled = true
    return 1
}

/// Вся работа с libmtp идёт через одну последовательную очередь:
/// библиотека не потокобезопасна, а MTP умеет только одну операцию за раз.
final class MTPService: @unchecked Sendable {
    static let shared = MTPService()

    private let queue = DispatchQueue(label: "shuttle.mtp", qos: .userInitiated)
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var vendorID: UInt16 = 0

    private init() { LIBMTP_Init() }

    /// Выполнить работу на очереди MTP.
    func run<T>(_ work: @escaping (MTPService) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work(self)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Для колбэков AppKit (перетаскивание в Finder).
    func runDetached(_ work: @escaping (MTPService) -> Void) {
        queue.async { work(self) }
    }

    // MARK: Подключение

    func connectIfNeeded() throws -> DeviceInfo {
        if device == nil {
            var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
            var count: Int32 = 0
            let err = LIBMTP_Detect_Raw_Devices(&raw, &count)
            guard err == LIBMTP_ERROR_NONE, count > 0, let raw else {
                if let raw { free(raw) }
                throw MTPError.notConnected
            }
            defer { free(raw) }
            vendorID = raw.pointee.device_entry.vendor_id
            guard let dev = LIBMTP_Open_Raw_Device_Uncached(raw) else { throw MTPError.busy }
            device = dev
        }
        return try info()
    }

    /// Обновляет данные о памяти; заодно проверяет, что телефон ещё на месте.
    func heartbeat() throws -> DeviceInfo { try info() }

    func release() {
        if let device { LIBMTP_Release_Device(device) }
        device = nil
    }

    private func info() throws -> DeviceInfo {
        guard let dev = device else { throw MTPError.notConnected }
        let r = LIBMTP_Get_Storage(dev, 0)
        if r < 0 {
            release()
            throw MTPError.notConnected
        }
        LIBMTP_Clear_Errorstack(dev)

        var storages: [StorageInfo] = []
        var cur = dev.pointee.storage
        while let st = cur {
            let v = st.pointee
            storages.append(StorageInfo(id: v.id,
                                        name: cleanStorageName(v.StorageDescription.map { String(cString: $0) }),
                                        capacity: v.MaxCapacity,
                                        free: v.FreeSpaceInBytes))
            cur = v.next
        }
        guard !storages.isEmpty else { throw MTPError.locked }

        var name = takeString(LIBMTP_Get_Friendlyname(dev)) ?? ""
        let model = takeString(LIBMTP_Get_Modelname(dev)) ?? ""
        if name.isEmpty { name = model.isEmpty ? "Устройство" : model }

        // Nintendo (0x057E) или DBI — это Switch, а не телефон.
        let joined = (name + " " + model).lowercased()
        let isConsole = vendorID == 0x057E || joined.contains("switch") || joined.contains("dbi")
        if isConsole && (name.isEmpty || name.lowercased() == "dbi") { name = "Nintendo Switch" }

        var maxLevel: UInt8 = 0, level: UInt8 = 0
        var battery: Int?
        if LIBMTP_Get_Batterylevel(dev, &maxLevel, &level) == 0, maxLevel > 0 {
            battery = Int(Double(level) / Double(maxLevel) * 100)
        } else {
            LIBMTP_Clear_Errorstack(dev)
        }

        return DeviceInfo(name: name, kind: isConsole ? .console : .phone, storages: storages, battery: battery)
    }

    /// «1: SD Card» → «SD Card».
    private func cleanStorageName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Память" }
        return raw.replacingOccurrences(of: #"^\s*\d+\s*:\s*"#, with: "", options: .regularExpression)
    }

    // MARK: Файлы

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem] {
        guard let dev = device else { throw MTPError.notConnected }
        var out: [RemoteItem] = []
        var cur = LIBMTP_Get_Files_And_Folders(dev, storage, parent)
        if cur == nil { LIBMTP_Clear_Errorstack(dev) }
        while let f = cur {
            let p = f.pointee
            out.append(RemoteItem(
                id: p.item_id,
                parentID: p.parent_id,
                storageID: p.storage_id,
                name: p.filename.map { String(cString: $0) } ?? "без имени",
                size: p.filesize,
                modified: Date(timeIntervalSince1970: TimeInterval(p.modificationdate)),
                isFolder: p.filetype == LIBMTP_FILETYPE_FOLDER))
            cur = p.next
            LIBMTP_destroy_file_t(f)
        }
        return out.sorted {
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
                throw MTPError.failed("Папка «\(path.joined(separator: "/"))» не найдена")
            }
            parent = f.id
            crumbs.append((f.id, f.name))
        }
        return crumbs
    }

    func download(_ id: UInt32, to url: URL, progress: @escaping (UInt64, UInt64) -> Bool) throws {
        guard let dev = device else { throw MTPError.notConnected }
        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box)
        defer { ctx.release() }
        let r = url.path.withCString { LIBMTP_Get_File_To_File(dev, id, $0, progressThunk, ctx.toOpaque()) }
        if r != 0 {
            let msg = lastError(dev)
            try? FileManager.default.removeItem(at: url)
            throw box.cancelled ? MTPError.cancelled : MTPError.failed(msg)
        }
    }

    @discardableResult
    func upload(_ url: URL, parent: UInt32, storage: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        guard let dev = device else { throw MTPError.notConnected }
        guard let f = LIBMTP_new_file_t() else { throw MTPError.failed("Не хватает памяти") }
        defer { LIBMTP_destroy_file_t(f) }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        f.pointee.filename = strdup(url.lastPathComponent)
        f.pointee.filesize = UInt64(values?.fileSize ?? 0)
        f.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        f.pointee.parent_id = parent
        f.pointee.storage_id = storage
        f.pointee.modificationdate = time_t((values?.contentModificationDate ?? Date()).timeIntervalSince1970)

        // В «отправлено» и «всего» libmtp включает служебный заголовок — меряем по размеру файла.
        let fileSize = f.pointee.filesize
        let box = ProgressBox { sent, _ in progress(min(sent, fileSize), fileSize) }
        let ctx = Unmanaged.passRetained(box)
        defer { ctx.release() }
        let r = url.path.withCString { LIBMTP_Send_File_From_File(dev, $0, f, progressThunk, ctx.toOpaque()) }
        if r != 0 {
            let msg = lastError(dev)
            throw box.cancelled ? MTPError.cancelled : MTPError.failed(msg)
        }
        return f.pointee.item_id
    }

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32 {
        guard let dev = device else { throw MTPError.notConnected }
        guard let cName = strdup(name) else { throw MTPError.failed("Не хватает памяти") }
        defer { free(cName) }
        let id = LIBMTP_Create_Folder(dev, cName, parent, storage)
        if id == 0 { throw MTPError.failed(lastError(dev, fallback: "Не удалось создать папку")) }
        return id
    }

    func delete(_ id: UInt32) throws {
        guard let dev = device else { throw MTPError.notConnected }
        if LIBMTP_Delete_Object(dev, id) != 0 {
            throw MTPError.failed(lastError(dev, fallback: "Не удалось удалить"))
        }
    }

    /// MTP не всегда удаляет непустые папки, поэтому идём снизу вверх.
    func deleteTree(_ item: RemoteItem) throws {
        if item.isFolder {
            for c in try list(storage: item.storageID, parent: item.id) { try deleteTree(c) }
        }
        try delete(item.id)
    }

    func rename(_ id: UInt32, to name: String) throws {
        guard let dev = device else { throw MTPError.notConnected }
        guard let cName = strdup(name) else { return }
        defer { free(cName) }
        if LIBMTP_Set_Object_Filename(dev, id, cName) != 0 {
            throw MTPError.failed(lastError(dev, fallback: "Не удалось переименовать"))
        }
    }

    // MARK: Деревья (папки целиком)

    func downloadTree(_ item: RemoteItem, into dir: URL, token: CancelToken,
                      progress: @escaping (UInt64, UInt64) -> Void) throws -> URL {
        var plan: [(RemoteItem, URL)] = []
        let fm = FileManager.default
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
        let target = uniqueURL(dir.appendingPathComponent(item.name))
        try walk(item, target)

        let total = plan.reduce(UInt64(0)) { $0 + $1.0.size }
        var done: UInt64 = 0
        progress(0, total)
        for (it, dest) in plan {
            if token.isCancelled { throw MTPError.cancelled }
            try download(it.id, to: dest) { sent, _ in
                progress(done + sent, total)
                return !token.isCancelled
            }
            done += it.size
        }
        progress(total, total)
        return target
    }

    func uploadTree(_ urls: [URL], parent: UInt32, storage: UInt32, token: CancelToken,
                    progress: @escaping (UInt64, UInt64) -> Void) throws {
        let fm = FileManager.default
        let total = urls.reduce(UInt64(0)) { $0 + localSize($1) }
        var done: UInt64 = 0
        progress(0, total)

        func send(_ url: URL, parent: UInt32) throws {
            if token.isCancelled { throw MTPError.cancelled }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let folderID = try createFolder(url.lastPathComponent, parent: parent, storage: storage)
                let kids = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])
                for k in kids { try send(k, parent: folderID) }
            } else {
                let size = localSize(url)
                try upload(url, parent: parent, storage: storage) { sent, _ in
                    progress(done + sent, total)
                    return !token.isCancelled
                }
                done += size
            }
        }
        for u in urls { try send(u, parent: parent) }
        progress(total, total)
    }

    // MARK: Утилиты

    private func lastError(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, fallback: String = "Ошибка передачи") -> String {
        defer { LIBMTP_Clear_Errorstack(dev) }
        guard let e = dev.pointee.errorstack, let t = e.pointee.error_text else { return fallback }
        return String(cString: t)
    }

    private func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
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
