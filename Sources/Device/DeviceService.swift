import Foundation

/// What to do if the device already has a file with that name.
enum ConflictPolicy {
    /// Same size — skip it (that's also how resuming after a drop works).
    case skipIdentical
    /// Delete the old one and upload again (homebrew and Atmosphère updates).
    case replace
}

/// All device work goes through one serial queue:
/// libmtp isn't thread-safe, and MTP can only do one operation at a time.
/// On top of the driver (MTP / ADB / test) — shared operations on folder trees.
final class DeviceService: @unchecked Sendable {
    static let shared = DeviceService()

    private let queue = DispatchQueue(label: "wirrow.device", qos: .userInitiated)
    private var candidates: [DeviceDriver]
    private(set) var active: DeviceDriver?
    /// Files whose upload was interrupted: their leftovers on the device can be deleted.
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

    /// Rebuild the driver list (ADB turned on or off in Settings).
    func reloadDrivers() {
        queue.async {
            self.active?.release()
            self.active = nil
            self.candidates = DeviceService.defaultDrivers()
        }
    }

    // MARK: Queue

    func run<T>(_ work: @escaping (DeviceService) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work(self)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// For AppKit callbacks (dragging to Finder).
    func runDetached(_ work: @escaping (DeviceService) -> Void) {
        queue.async { work(self) }
    }

    /// For tests: run synchronously on the queue.
    func sync<T>(_ work: (DeviceService) throws -> T) rethrows -> T {
        try queue.sync { try work(self) }
    }

    private func driver() throws -> DeviceDriver {
        guard let active else { throw MTPError.notConnected }
        return active
    }

    // MARK: Connection

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
                // The device is there but busy or locked — stop looking.
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

    // MARK: Files

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem] {
        try driver().list(storage: storage, parent: parent).sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Find a folder by a path of names, e.g. ["DCIM", "Camera"].
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

    /// A folder with that name or a new one. The whole path is created: ["switch", "DBI"].
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

    /// MTP doesn't always delete non-empty folders, so we go bottom-up.
    func deleteTree(_ item: RemoteItem) throws {
        if item.isFolder {
            for c in try list(storage: item.storageID, parent: item.id) { try deleteTree(c) }
        }
        try driver().delete(item.id)
    }

    // MARK: Trees

    /// All files inside a folder with paths relative to it.
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

    /// Search by name in a folder and all its subfolders. Matches are reported as we go.
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

    /// Download a file or a whole folder.
    /// `resumeInto` — continue into an already started place: finished files are skipped, partial ones resumed.
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
                // Verification: the Mac must get exactly as many bytes as the device has. If not — download again.
                if it.size > 0, localSize(dest) != it.size {
                    try? fm.removeItem(at: dest)
                    try d.download(it, to: dest, offset: 0) { sent, _ in
                        progress(base + sent, total)
                        return !token.isCancelled
                    }
                    if localSize(dest) != it.size {
                        try? fm.removeItem(at: dest)
                        throw MTPError.failed(L("«%@» скачался не полностью", it.name))
                    }
                }
                token.noteVerified()
            } catch MTPError.interrupted {
                // A drop: keep the partial file — we'll continue from there.
                throw MTPError.interrupted
            } catch {
                // Cancelled or failed: the partial file isn't needed.
                try? fm.removeItem(at: dest)
                throw error
            }
            done += it.size
        }
        progress(total, total)
        return target
    }

    /// Upload files and folders. Folders merge with existing ones.
    func uploadTree(_ urls: [URL], parent: UInt32, storage: UInt32, token: CancelToken,
                    conflict: ConflictPolicy = .skipIdentical,
                    progress: @escaping (UInt64, UInt64) -> Void) throws {
        let d = try driver()
        let fm = FileManager.default
        let total = urls.reduce(UInt64(0)) { $0 + localSize($1) }
        var done: UInt64 = 0
        progress(0, total)
        // Read destination folder contents once: MTP takes seconds on big folders.
        var listings: [UInt32: [RemoteItem]] = [:]
        func existing(in parent: UInt32) throws -> [RemoteItem] {
            if let l = listings[parent] { return l }
            let l = try list(storage: storage, parent: parent)
            listings[parent] = l
            return l
        }

        func send(_ url: URL, parent: UInt32) throws {
            if token.isCancelled { throw MTPError.cancelled }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let existing = try existing(in: parent)
            let name = url.lastPathComponent
            if isDir.boolValue {
                let folderID: UInt32
                if let f = existing.first(where: { $0.isFolder && $0.name == name }) {
                    folderID = f.id
                } else {
                    folderID = try d.createFolder(name, parent: parent, storage: storage)
                    listings[folderID] = [] // a new folder is empty — no need to read it
                }
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
                // Replacing, or the leftover of an interrupted upload.
                if conflict == .replace || partialUploads.contains(key) { try d.delete(old.id) }
            }
            let base = done
            partialUploads.insert(key)
            do {
                var id = try d.upload(url, parent: parent, storage: storage) { sent, _ in
                    progress(base + sent, total)
                    return !token.isCancelled
                }
                // Verification: the device must report the same size. Clearly truncated — upload again.
                // Larger or zero (DBI installs and removes the file) — leave it: that's not a drop.
                if let got = d.remoteSize(id), got > 0, got < size {
                    try? d.delete(id)
                    id = try d.upload(url, parent: parent, storage: storage) { sent, _ in
                        progress(base + sent, total)
                        return !token.isCancelled
                    }
                    if let again = d.remoteSize(id), again > 0, again < size {
                        try? d.delete(id)
                        throw MTPError.failed(L("«%@» загрузился не полностью", name))
                    }
                }
                if d.remoteSize(id) == size { token.noteVerified() }
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

    // MARK: Verification against the copy on the Mac

    enum Sameness { case identical, different, unknown }

    /// Is this the same file as on the Mac. Size is required; then SHA-256 on the device (ADB)
    /// or three 64 KB content samples: start, middle, end (MTP).
    func compare(_ item: RemoteItem, with url: URL) -> Sameness {
        guard let d = active, item.size > 0, localSize(url) == item.size else { return .different }
        if let remote = d.sha256(item) {
            return remote.lowercased() == sha256Hex(of: url) ? .identical : .different
        }
        let len = UInt32(min(UInt64(64 * 1024), item.size))
        let offsets = Set([0, (item.size - UInt64(len)) / 2, item.size - UInt64(len)])
        guard let h = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? h.close() }
        for off in offsets.sorted() {
            guard let remote = d.readRange(item, offset: off, length: len) else { return .unknown }
            try? h.seek(toOffset: off)
            guard let local = try? h.read(upToCount: Int(len)), local == remote else { return .different }
        }
        return .identical
    }
}
