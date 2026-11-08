import Foundation

private final class ProgressBox {
    let handler: (UInt64, UInt64) -> Bool
    var cancelled = false
    init(_ handler: @escaping (UInt64, UInt64) -> Bool) { self.handler = handler }
}

private let progressThunk: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    if box.handler(min(sent, total), total) { return 0 }
    box.cancelled = true
    return 1
}

/// Android (режим «Передача файлов») и Switch с DBI через libmtp.
final class MTPDriver: DeviceDriver {
    let transport: Transport = .mtp
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var vendorID: UInt16 = 0
    private var partial = false

    /// Физическое устройство на шине USB. nil — первое найденное (как раньше, для самопроверки).
    struct RawID: Hashable, Sendable {
        let bus: UInt32
        let devnum: UInt8
        let vendor: UInt16
        var slot: String { "mtp:\(bus):\(devnum)" }
    }
    let target: RawID?

    init(target: RawID? = nil) {
        LIBMTP_Init()
        self.target = target
    }

    /// Все MTP-устройства, видимые сейчас по USB.
    static func detect() -> [RawID] {
        LIBMTP_Init()
        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&raw, &count)
        guard err == LIBMTP_ERROR_NONE, count > 0, let raw else {
            if let raw { free(raw) }
            return []
        }
        defer { free(raw) }
        return (0..<Int(count)).map { i in
            let r = raw[i]
            return RawID(bus: r.bus_location, devnum: r.devnum, vendor: r.device_entry.vendor_id)
        }
    }

    var supportsPartialDownload: Bool { partial }

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
            // Своё устройство среди найденных: по шине и номеру на ней.
            var index = 0
            if let target {
                guard let i = (0..<Int(count)).first(where: { raw[$0].bus_location == target.bus && raw[$0].devnum == target.devnum })
                else { throw MTPError.notConnected }
                index = i
            }
            let entry = raw.advanced(by: index)
            vendorID = entry.pointee.device_entry.vendor_id
            guard let dev = LIBMTP_Open_Raw_Device_Uncached(entry) else { throw MTPError.busy }
            device = dev
            partial = LIBMTP_Check_Capability(dev, LIBMTP_DEVICECAP_GetPartialObject) != 0
        }
        return try info()
    }

    func release() {
        if let device { LIBMTP_Release_Device(device) }
        device = nil
    }

    private func dev() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw MTPError.notConnected }
        return device
    }

    private func info() throws -> DeviceInfo {
        let dev = try dev()
        if LIBMTP_Get_Storage(dev, 0) < 0 {
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
                                        capacity: v.MaxCapacity, free: v.FreeSpaceInBytes))
            cur = v.next
        }
        guard !storages.isEmpty else { throw MTPError.locked }

        var name = takeString(LIBMTP_Get_Friendlyname(dev)) ?? ""
        let model = takeString(LIBMTP_Get_Modelname(dev)) ?? ""
        if name.isEmpty { name = model.isEmpty ? L("Устройство") : model }
        let serial = takeString(LIBMTP_Get_Serialnumber(dev)) ?? ""

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
        return DeviceInfo(name: name, kind: isConsole ? .console : .phone, storages: storages,
                          battery: battery, serial: serial, transport: .mtp)
    }

    /// «1: SD Card» → «SD Card».
    private func cleanStorageName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return L("Память") }
        return raw.replacingOccurrences(of: #"^\s*\d+\s*:\s*"#, with: "", options: .regularExpression)
    }

    // MARK: Файлы

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem] {
        let dev = try dev()
        var out: [RemoteItem] = []
        var cur = LIBMTP_Get_Files_And_Folders(dev, storage, parent)
        if cur == nil { LIBMTP_Clear_Errorstack(dev) }
        while let f = cur {
            let p = f.pointee
            out.append(RemoteItem(
                id: p.item_id, parentID: p.parent_id, storageID: p.storage_id,
                name: p.filename.map { String(cString: $0) } ?? L("без имени"),
                size: p.filesize,
                modified: Date(timeIntervalSince1970: TimeInterval(p.modificationdate)),
                isFolder: p.filetype == LIBMTP_FILETYPE_FOLDER))
            cur = p.next
            LIBMTP_destroy_file_t(f)
        }
        return out
    }

    func download(_ item: RemoteItem, to url: URL, offset: UInt64,
                  progress: @escaping (UInt64, UInt64) -> Bool) throws {
        let dev = try dev()
        if offset > 0, partial, offset < item.size {
            try downloadPartial(dev, item, to: url, offset: offset, progress: progress)
            return
        }
        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box)
        defer { ctx.release() }
        let r = url.path.withCString { LIBMTP_Get_File_To_File(dev, item.id, $0, progressThunk, ctx.toOpaque()) }
        if r != 0 {
            try? FileManager.default.removeItem(at: url)
            throw failure(dev, cancelled: box.cancelled, fallback: L("Ошибка скачивания"))
        }
    }

    /// Докачка: дописываем к файлу кусками по 1 МБ.
    private func downloadPartial(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ item: RemoteItem,
                                 to url: URL, offset: UInt64, progress: (UInt64, UInt64) -> Bool) throws {
        guard let h = try? FileHandle(forWritingTo: url) else { throw MTPError.failed(L("Не удалось открыть файл")) }
        defer { try? h.close() }
        try h.truncate(atOffset: offset)
        try h.seekToEnd()
        var pos = offset
        let chunk: UInt32 = 1 << 20
        while pos < item.size {
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            let r = LIBMTP_GetPartialObject(dev, item.id, pos, min(chunk, UInt32(item.size - pos)), &data, &size)
            guard r == 0, let data, size > 0 else {
                if let data { free(data) }
                throw failure(dev, cancelled: false, fallback: L("Ошибка докачки"))
            }
            h.write(Data(bytes: data, count: Int(size)))
            free(data)
            pos += UInt64(size)
            if !progress(pos, item.size) { throw MTPError.cancelled }
        }
    }

    @discardableResult
    func upload(_ url: URL, parent: UInt32, storage: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        let dev = try dev()
        guard let f = LIBMTP_new_file_t() else { throw MTPError.failed(L("Не хватает памяти")) }
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
        if r != 0 { throw failure(dev, cancelled: box.cancelled, fallback: L("Ошибка загрузки")) }
        return f.pointee.item_id
    }

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32 {
        let dev = try dev()
        guard let cName = strdup(name) else { throw MTPError.failed(L("Не хватает памяти")) }
        defer { free(cName) }
        let id = LIBMTP_Create_Folder(dev, cName, parent, storage)
        if id == 0 { throw failure(dev, cancelled: false, fallback: L("Не удалось создать папку")) }
        return id
    }

    func delete(_ id: UInt32) throws {
        let dev = try dev()
        if LIBMTP_Delete_Object(dev, id) != 0 { throw failure(dev, cancelled: false, fallback: L("Не удалось удалить")) }
    }

    func rename(_ id: UInt32, to name: String) throws {
        let dev = try dev()
        guard let cName = strdup(name) else { return }
        defer { free(cName) }
        if LIBMTP_Set_Object_Filename(dev, id, cName) != 0 {
            throw failure(dev, cancelled: false, fallback: L("Не удалось переименовать"))
        }
    }

    func thumbnail(_ item: RemoteItem) -> Data? {
        guard let dev = device else { return nil }
        var data: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        let r = LIBMTP_Get_Thumbnail(dev, item.id, &data, &size)
        defer { if let data { free(data) } }
        guard r == 0, let data, size > 0 else { LIBMTP_Clear_Errorstack(dev); return nil }
        return Data(bytes: data, count: Int(size))
    }

    // MARK: Сверка

    func remoteSize(_ id: UInt32) -> UInt64? {
        guard let dev = device, let f = LIBMTP_Get_Filemetadata(dev, id) else {
            if let device { LIBMTP_Clear_Errorstack(device) }
            return nil
        }
        defer { LIBMTP_destroy_file_t(f) }
        return f.pointee.filesize
    }

    func readRange(_ item: RemoteItem, offset: UInt64, length: UInt32) -> Data? {
        guard let dev = device, partial, length > 0 else { return nil }
        var data: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        let r = LIBMTP_GetPartialObject(dev, item.id, offset, length, &data, &size)
        defer { if let data { free(data) } }
        guard r == 0, let data, size > 0 else { LIBMTP_Clear_Errorstack(dev); return nil }
        return Data(bytes: data, count: Int(size))
    }

    // MARK: Ошибки

    /// Если кабель отошёл — `.interrupted` (передачу продолжим), иначе текст ошибки libmtp.
    private func failure(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, cancelled: Bool, fallback: String) -> MTPError {
        if cancelled { LIBMTP_Clear_Errorstack(dev); return .cancelled }
        var text = fallback
        if let e = dev.pointee.errorstack, let t = e.pointee.error_text { text = String(cString: t) }
        LIBMTP_Clear_Errorstack(dev)
        if LIBMTP_Get_Storage(dev, 0) < 0 {
            release()
            return .interrupted
        }
        return .failed(text)
    }

    private func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
