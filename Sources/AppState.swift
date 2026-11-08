import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Crumb: Hashable {
    let id: UInt32
    let name: String
}

struct LocalItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let size: UInt64
    let modified: Date
    let isFolder: Bool
}

/// A folder on the device: storage + folder id.
struct FolderKey: Hashable {
    let storage: UInt32
    let folder: UInt32
}

/// A tree row: item, nesting depth and (for search) the path.
struct RemoteRow: Identifiable {
    let item: RemoteItem
    let depth: Int
    var path: String? = nil
    var id: UInt32 { item.id }
}

enum Connection: Equatable {
    case searching
    case busy
    case locked
    case connected(DeviceInfo)

    var info: DeviceInfo? {
        if case .connected(let i) = self { return i }
        return nil
    }
}

enum SortKey: String { case name, date, size }

struct SortOrder: Equatable {
    var key: SortKey = .name
    var ascending = true
}

/// The pane clicked last: menu commands apply to it.
enum Side { case mac, device }

enum ViewMode: String { case list, grid }

struct QuickFolder: Identifiable {
    let id: String
    let title: String
    let icon: String
    let path: [String]

    static var android: [QuickFolder] { [
        .init(id: "camera", title: L("Камера"), icon: "camera", path: ["DCIM", "Camera"]),
        .init(id: "download", title: L("Загрузки"), icon: "arrow.down.circle", path: ["Download"]),
        .init(id: "pictures", title: L("Фото"), icon: "photo", path: ["Pictures"]),
        .init(id: "movies", title: L("Видео"), icon: "film", path: ["Movies"]),
        .init(id: "music", title: L("Музыка"), icon: "music.note", path: ["Music"]),
        .init(id: "docs", title: L("Документы"), icon: "doc.text", path: ["Documents"]),
    ] }
}

/// A connected device — a tab above the panes.
struct DeviceTab: Identifiable, Equatable {
    /// Place on the bus (`DeviceHub.Slot.id`).
    let slot: String
    var info: DeviceInfo
    let service: DeviceService
    var id: String { slot }
    static func == (a: DeviceTab, b: DeviceTab) -> Bool { a.slot == b.slot && a.info == b.info }
}

/// What was open on a device — restored when we switch back to its tab.
private struct DeviceView {
    var storageID: UInt32?
    var androidPath: [Crumb]
    var cache: [FolderKey: [RemoteItem]]
    var expanded: Set<FolderKey>
    var activeQuick: String?
    var viewMode: ViewMode
    var newPhotos: [RemoteItem]
}

@MainActor
final class AppState: ObservableObject {
    /// Service of the device on the current tab. Transfers remember their own service.
    private(set) var svc: DeviceService
    private let hub: DeviceHub

    // Device
    @Published var connection: Connection = .searching
    /// All connected devices — tabs, if there is more than one.
    @Published private(set) var devices: [DeviceTab] = []
    @Published private(set) var selectedSlot: String?
    private var views: [String: DeviceView] = [:]
    /// Devices for which "connected" (photos, sync) already ran this time.
    private var introduced: Set<String> = []
    /// Bus places where the same phone shows up a second time (over MTP when it's already there over ADB).
    private var shadowed: [String: String] = [:]
    @Published var storageID: UInt32?
    @Published var androidPath: [Crumb] = []
    @Published var androidSelection: Set<UInt32> = []
    @Published var activeQuick: String?
    @Published var expanded: Set<FolderKey> = []
    @Published private(set) var loadingKeys: Set<FolderKey> = []
    /// Folder listing cache: MTP takes seconds to list big folders
    /// (Camera with 600+ photos — about 16 s on a Huawei), so we don't re-read them.
    @Published var cache: [FolderKey: [RemoteItem]] = [:]
    /// A Switch is connected over USB, but DBI hasn't turned on MTP.
    @Published var nintendoWithoutMTP = false

    // View
    @Published var sort = SortOrder()
    @Published var showHidden: Bool = AppSettings.defaults.bool(forKey: "showHidden") {
        didSet { AppSettings.defaults.set(showHidden, forKey: "showHidden") }
    }
    @Published var viewMode: ViewMode = .list

    // Search
    @Published var searchText = ""
    @Published var deepResults: [RemoteRow]?
    @Published var deepSearching = false
    @Published var deepScanned = 0
    var searchToken: CancelToken?

    // Mac
    @Published var macURL: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @Published var macItems: [LocalItem] = []
    @Published var macSelection: Set<URL> = []
    /// "name|size" of files in the current Mac folder and the photos folder — for the "already on Mac" badge.
    @Published var macIndex: Set<String> = []
    var photosIndex: Set<String> = []

    // Queue
    @Published var transfers: [Transfer] = []
    @Published var errorMessage: String?
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?
    private var reservedTargets: Set<String> = []
    private var batchCount = 0
    private var batchBytes: UInt64 = 0

    // Dialogs (opened both from the pane and from the menu bar)
    @Published var activeSide: Side = .device
    @Published var askNewFolder = false
    @Published var renaming: RemoteItem?
    @Published var toDelete: [RemoteItem] = []
    @Published var dialogText = ""
    @Published var renameRequest: RenameRequest?
    @Published var pendingInstall: PendingInstall?
    @Published var pendingHomebrew: URL?
    @Published var pendingAPK: [URL]?
    @Published var atmosphere: AtmosphereRelease?
    @Published var atmosphereChecking = false
    @Published var showHistory = false
    @Published var showSync = false
    @Published var showDuplicates = false
    @Published var showCleanup = false
    @Published var duplicates: [RemoteItem] = []
    @Published var newPhotos: [RemoteItem] = []

    /// What is being dragged from the device pane inside the app.
    var draggingRemote: [RemoteItem] = []

    private var monitor: Task<Void, Never>?
    private var lastDeviceKey: String?

    /// `service`/`services` — given devices (tests); without them — everything `DeviceHub` finds.
    init(preview: Bool = false, service: DeviceService? = nil, services: [DeviceService] = []) {
        let given = (service.map { [$0] } ?? []) + services
        if let first = given.first {
            svc = first
            hub = DeviceHub(fixed: given.enumerated().map { .init(id: "fixed\($0.offset)", service: $0.element) })
        } else {
            svc = DeviceService(drivers: [])
            hub = .shared
        }
        if preview || AppFolders.testing { return }
        // Thumbnails wait while transfers run; leaving a folder clears the thumbnail queue.
        Thumbnails.shared.isBusy = { [weak self] in self?.hasActiveTransfers ?? false }
        Thumbnails.shared.service = { [weak self] key in self?.service(for: key) }
        loadMac()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Derived

    var device: DeviceInfo? { connection.info }
    var deviceKey: String { device?.key ?? "" }
    var currentStorage: StorageInfo? { device?.storages.first { $0.id == storageID } }
    var currentAndroidFolder: UInt32 { androidPath.last?.id ?? mtpRoot }
    var currentKey: FolderKey? { storageID.map { FolderKey(storage: $0, folder: currentAndroidFolder) } }
    var androidLoading: Bool { currentKey.map(loadingKeys.contains) ?? false }
    var hasActiveTransfers: Bool { transfers.contains { $0.state.isActive } }
    var isConsole: Bool { device?.kind == .console }

    /// On a phone we hide dot folders; on a Switch they matter (.overlays).
    var hidesDotFiles: Bool { !showHidden && device?.kind == .phone }

    /// Path of the current folder as names (without the storage).
    var currentPathNames: [String] { androidPath.dropFirst().map(\.name) }

    var androidItems: [RemoteItem] {
        guard let k = currentKey else { return [] }
        return arranged(cache[k] ?? [])
    }

    /// The current folder with expanded subfolders, flattened into a list (and filtered by search).
    var androidRows: [RemoteRow] {
        if let deepResults { return deepResults }
        guard let k = currentKey else { return [] }
        var rows: [RemoteRow] = []
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        func add(_ key: FolderKey, depth: Int) {
            for item in arranged(cache[key] ?? []) {
                let child = FolderKey(storage: item.storageID, folder: item.id)
                let open = item.isFolder && expanded.contains(child) && depth < 12
                if q.isEmpty || item.name.lowercased().contains(q) || open {
                    rows.append(RemoteRow(item: item, depth: depth))
                }
                if open { add(child, depth: depth + 1) }
            }
        }
        add(k, depth: 0)
        return rows
    }

    func isExpanded(_ item: RemoteItem) -> Bool {
        expanded.contains(FolderKey(storage: item.storageID, folder: item.id))
    }

    func isLoading(_ item: RemoteItem) -> Bool {
        loadingKeys.contains(FolderKey(storage: item.storageID, folder: item.id))
    }

    func isOnMac(_ item: RemoteItem) -> Bool {
        guard !item.isFolder else { return false }
        return Duplicates.isOnMac(item, index: macIndex) || ImportLedger.shared.contains(item, device: deviceKey)
    }

    func arranged(_ items: [RemoteItem]) -> [RemoteItem] {
        let visible = hidesDotFiles ? items.filter { !$0.name.hasPrefix(".") } : items
        return visible.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let r: Bool
            switch sort.key {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: r = a.modified < b.modified
            case .size: r = a.size < b.size
            }
            return sort.ascending ? r : !r
        }
    }

    func toggleSort(_ key: SortKey) {
        if sort.key == key { sort.ascending.toggle() } else { sort = SortOrder(key: key, ascending: key == .name) }
        loadMac()
    }

    // MARK: Connection

    /// Poll every 2 seconds: which devices are connected, what's up with the current tab.
    func tick() async {
        // While a transfer runs we don't scan the USB bus — looking for new devices could disturb it.
        let slots = await hub.refresh(scan: !hasActiveTransfers)
        var found: [DeviceTab] = []
        var trouble: Connection?
        for slot in slots {
            // A duplicate of an already connected phone (the same one as over ADB) — don't reopen it every 2 seconds.
            if let key = shadowed[slot.id], found.contains(where: { $0.info.key == key }) { continue }
            // While a device is busy with a transfer or a folder listing, leave it alone — reuse the last info.
            if let known = devices.first(where: { $0.slot == slot.id }), isBusy(known) {
                found.append(known)
                continue
            }
            do {
                let info = try await slot.service.run { try $0.connectIfNeeded() }
                // The same phone over ADB and over MTP — keep the first one (ADB).
                if found.contains(where: { $0.info.key == info.key }) {
                    shadowed[slot.id] = info.key
                    slot.service.runDetached { $0.release() }
                    continue
                }
                shadowed[slot.id] = nil
                found.append(DeviceTab(slot: slot.id, info: info, service: slot.service))
            } catch let e as MTPError {
                if e == .busy { trouble = .busy } else if e == .locked, trouble == nil { trouble = .locked }
            } catch {}
        }
        apply(found, trouble: trouble)
    }

    private func isBusy(_ tab: DeviceTab) -> Bool {
        transfers.contains { $0.state.isActive && $0.deviceKey == tab.info.key }
            || (tab.slot == selectedSlot && !loadingKeys.isEmpty)
    }

    private func apply(_ found: [DeviceTab], trouble: Connection?) {
        let gone = devices.filter { d in !found.contains { $0.slot == d.slot } }
        for d in gone {
            views[d.slot] = nil
            introduced.remove(d.info.key)
        }
        if devices != found { devices = found }
        // The cable may have been replugged faster than one poll — always resume what was interrupted.
        for d in found { resumeWaiting(for: d.info.key) }

        if let sel = selectedSlot, let tab = found.first(where: { $0.slot == sel }) {
            svc = tab.service
            setConnection(.connected(tab.info))
            if nintendoWithoutMTP { nintendoWithoutMTP = false }
            if !tab.info.storages.contains(where: { $0.id == storageID }), let first = tab.info.storages.first {
                cache = [:]
                expanded = []
                selectStorage(first.id)
            }
        } else if let first = found.first {
            // The current device is gone (or there was none) — switch to the first remaining one.
            if selectedSlot != nil { resetDevice() }
            show(first)
        } else {
            let wasConnected = device != nil
            selectedSlot = nil
            setConnection(trouble ?? .searching)
            if wasConnected { resetDevice() }
            let nintendo = connection == .searching && USBProbe.nintendoPresent()
            if nintendo != nintendoWithoutMTP { nintendoWithoutMTP = nintendo }
        }
    }

    /// Switch to a device's tab.
    func selectDevice(_ slot: String) {
        guard slot != selectedSlot, let tab = devices.first(where: { $0.slot == slot }) else { return }
        // Remember what was open on the previous device.
        if let cur = selectedSlot {
            views[cur] = DeviceView(storageID: storageID, androidPath: androidPath, cache: cache, expanded: expanded,
                                    activeQuick: activeQuick, viewMode: viewMode, newPhotos: newPhotos)
        }
        clearSearch()
        androidSelection = []
        Thumbnails.shared.cancelQueued()
        show(tab)
    }

    private func show(_ tab: DeviceTab) {
        selectedSlot = tab.slot
        svc = tab.service
        setConnection(.connected(tab.info))
        if nintendoWithoutMTP { nintendoWithoutMTP = false }
        if let v = views[tab.slot] {
            storageID = v.storageID
            androidPath = v.androidPath
            cache = v.cache
            expanded = v.expanded
            activeQuick = v.activeQuick
            viewMode = v.viewMode
            newPhotos = v.newPhotos
        } else {
            cache = [:]
            expanded = []
            newPhotos = []
            if let first = tab.info.storages.first { selectStorage(first.id) }
        }
        if introduced.insert(tab.info.key).inserted {
            lastDeviceKey = tab.info.key
            deviceConnected(tab.info)
        }
    }

    /// A device's service by its key — after a drop the transfer continues on it, wherever it is now.
    func service(for key: String) -> DeviceService? {
        devices.first { $0.info.key == key }?.service
    }

    /// Don't publish the same thing every 2 seconds — otherwise the whole window redraws for nothing.
    private func setConnection(_ c: Connection) {
        if connection != c { connection = c }
    }

    private func resumeWaiting(for key: String) {
        for t in transfers where t.state == .waiting && t.deviceKey == key {
            t.prepareRetry()
            t.restart?()
        }
    }

    private func resetDevice() {
        cache = [:]
        expanded = []
        storageID = nil
        androidPath = []
        androidSelection = []
        newPhotos = []
        clearSearch()
    }

    /// A device connected: resume interrupted transfers, check for new photos, sync.
    private func deviceConnected(_ info: DeviceInfo) {
        Achievements.shared.recordDevice(console: info.kind == .console)
        if info.kind == .phone {
            // Photos folder index first, then count new ones — otherwise what's already downloaded counts as new.
            Task {
                await refreshPhotosIndexNow()
                await refreshNewPhotos()
                // Auto-import: new photos download by themselves, even with the window closed.
                if AppSettings.shared.autoImport, !newPhotos.isEmpty { importNewPhotos() }
            }
            if AppSettings.shared.autoSync { runSyncs(SyncStore.shared.rules(for: info.key).filter(\.enabled)) }
        }
    }

    // MARK: Device navigation

    func selectStorage(_ id: UInt32) {
        guard let s = device?.storages.first(where: { $0.id == id }) else { return }
        storageID = id
        androidPath = [Crumb(id: mtpRoot, name: s.name)]
        androidSelection = []
        activeQuick = nil
        clearSearch()
        viewMode = s.isAlbum ? .grid : .list
        Task { await loadAndroid(force: false) }
    }

    func fetch(_ key: FolderKey, force: Bool) async {
        if !force, cache[key] != nil { return }
        if loadingKeys.contains(key) { return }
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }
        do {
            cache[key] = try await svc.run { try $0.list(storage: key.storage, parent: key.folder) }
        } catch {
            show(error)
        }
    }

    /// `force: false` — take it from the cache if the folder was opened before.
    func loadAndroid(force: Bool = true) async {
        guard let k = currentKey else { return }
        await fetch(k, force: force)
        androidSelection = []
    }

    /// The Refresh button: the current folder and every folder expanded in it.
    func refreshAndroid() {
        guard let k = currentKey else { return }
        let keys = [k] + expanded.filter { $0.storage == k.storage && cache[$0] != nil }
        Task { for key in keys { await fetch(key, force: true) } }
    }

    func toggleExpand(_ item: RemoteItem) {
        guard item.isFolder else { return }
        let key = FolderKey(storage: item.storageID, folder: item.id)
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
            Task { await fetch(key, force: false) }
        }
    }

    func openAndroid(_ item: RemoteItem) {
        guard item.isFolder else { return }
        if deepResults != nil, let row = deepResults?.first(where: { $0.item.id == item.id }), let path = row.path {
            // From search results: open the folder by its path.
            clearSearch()
            open(path: path.split(separator: "/").map(String.init) + [item.name])
            return
        }
        androidPath.append(Crumb(id: item.id, name: item.name))
        activeQuick = nil
        searchText = ""
        Thumbnails.shared.cancelQueued()
        Task { await loadAndroid(force: false) }
    }

    func goToCrumb(_ index: Int) {
        guard index < androidPath.count - 1 else { return }
        androidPath = Array(androidPath.prefix(index + 1))
        activeQuick = nil
        Task { await loadAndroid(force: false) }
    }

    func androidUp() {
        if deepResults != nil { clearSearch(); return }
        if androidPath.count > 1 { goToCrumb(androidPath.count - 2) }
    }

    /// Open a folder by a path of names on the current storage.
    func open(path: [String], storage: StorageInfo? = nil, quick: String? = nil) {
        guard let st = storage ?? currentStorage else { return }
        if st.id != storageID { selectStorage(st.id) }
        activeQuick = quick
        Task {
            do {
                let crumbs = try await svc.run { try $0.resolve(path: path, storage: st.id) }
                androidPath = [Crumb(id: mtpRoot, name: st.name)] + crumbs.map { Crumb(id: $0.id, name: $0.name) }
                await loadAndroid(force: false)
            } catch {
                activeQuick = nil
                show(error)
            }
        }
    }

    func openQuick(_ q: QuickFolder) { open(path: q.path, quick: q.id) }

    func parentKey(_ item: RemoteItem) -> FolderKey {
        FolderKey(storage: item.storageID, folder: item.parentID == 0 ? mtpRoot : item.parentID)
    }

    /// Re-read a folder after a change: the current one always, others only if cached.
    func invalidate(_ key: FolderKey) async {
        if key == currentKey || cache[key] != nil { await fetch(key, force: true) }
    }

    func createAndroidFolder(_ name: String) {
        guard let k = currentKey, !name.isEmpty else { return }
        Task {
            do {
                _ = try await svc.run { try $0.createFolder(name, parent: k.folder, storage: k.storage) }
            } catch { show(error) }
            await invalidate(k)
        }
    }

    func deleteAndroid(_ items: [RemoteItem]) {
        let parents = Set(items.map(parentKey))
        Task {
            do {
                try await svc.run { svc in
                    for i in items { try svc.deleteTree(i) }
                }
                toast(L("Удалено: %d", items.count))
            } catch { show(error) }
            for p in parents { await invalidate(p) }
            if deepResults != nil { deepResults?.removeAll { r in items.contains { $0.id == r.item.id } } }
            await refreshDevice()
        }
    }

    func renameAndroid(_ item: RemoteItem, to name: String) {
        guard !name.isEmpty, name != item.name else { return }
        Task {
            do { try await svc.run { try $0.rename(item.id, to: name) } } catch { show(error) }
            await invalidate(parentKey(item))
        }
    }

    func selectedRemote(orItem item: RemoteItem) -> [RemoteItem] {
        guard androidSelection.contains(item.id) else { return [item] }
        return androidRows.map(\.item).filter { androidSelection.contains($0.id) }
    }

    func refreshDevice() async {
        if let info = try? await svc.run({ try $0.heartbeat() }) { connection = .connected(info) }
    }

    // MARK: Mac

    func loadMac() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: macURL, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        let items = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return LocalItem(url: u, name: u.lastPathComponent, size: UInt64(v?.fileSize ?? 0),
                             modified: v?.contentModificationDate ?? .distantPast,
                             isFolder: v?.isDirectory ?? false)
        }
        macItems = items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let r: Bool
            switch sort.key {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: r = a.modified < b.modified
            case .size: r = a.size < b.size
            }
            return sort.ascending ? r : !r
        }
        macSelection = macSelection.filter { s in macItems.contains { $0.url == s } }
        macIndex = Duplicates.localIndex(macURL, recursive: false).union(photosIndex)
    }

    /// Photos folder index (recursive, in the background).
    func refreshPhotosIndex() {
        Task { await refreshPhotosIndexNow() }
    }

    func refreshPhotosIndexNow() async {
        let dir = photosDestination
        let idx = await Task.detached(priority: .utility) { Duplicates.localIndex(dir, recursive: true) }.value
        photosIndex = idx
        macIndex = macIndex.union(idx)
    }

    func openMac(_ item: LocalItem) {
        if item.isFolder {
            setMac(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func macUp() {
        let parent = macURL.deletingLastPathComponent()
        guard parent.path != macURL.path else { return }
        setMac(parent)
    }

    func setMac(_ url: URL) {
        macURL = url
        macSelection = []
        loadMac()
    }

    func chooseMacFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = macURL
        panel.prompt = L("Выбрать")
        if panel.runModal() == .OK, let u = panel.url { setMac(u) }
    }

    func selectedLocal(orItem item: LocalItem) -> [LocalItem] {
        macSelection.contains(item.url) ? macItems.filter { macSelection.contains($0.url) } : [item]
    }

    // MARK: Transfer engine

    /// Start a transfer. `work` runs on the device queue and returns the result on the Mac (if any).
    /// If the connection drops, the transfer waits for the same device and continues by itself.
    func run(_ t: Transfer, completion: (@MainActor (Transfer) -> Void)? = nil,
             work: @escaping (DeviceService, Transfer) throws -> URL?) {
        transfers.insert(t, at: 0)
        Notifier.prepare()
        let started = svc
        t.restart = { [weak self, weak t] in
            guard let self, let t else { return }
            // After a drop the same device may come back at another bus place — find it by key.
            self.execute(t, on: self.service(for: t.deviceKey) ?? started, completion: completion, work: work)
        }
        execute(t, on: started, completion: completion, work: work)
    }

    private func execute(_ t: Transfer, on service: DeviceService, completion: (@MainActor (Transfer) -> Void)?,
                         work: @escaping (DeviceService, Transfer) throws -> URL?) {
        Task {
            do {
                let url = try await service.run { svc -> URL? in
                    if t.token.isCancelled { throw MTPError.cancelled }
                    t.began()
                    return try work(svc, t)
                }
                if let url { t.resultURL = url }
                t.finish(nil)
            } catch {
                t.finish(error)
            }
            if t.state == .waiting { return }
            finished(t)
            completion?(t)
        }
    }

    private func finished(_ t: Transfer) {
        if let path = t.resultURL?.path { reservedTargets.remove(path) }
        guard t.state != .cancelled else { return }
        HistoryStore.shared.add(HistoryEntry(
            date: Date(), name: (t.label.map { $0 + ": " } ?? "") + t.name, toMac: t.direction == .toMac,
            bytes: t.total, device: device?.name ?? "", macPath: t.resultURL?.path,
            ok: t.state == .done, note: { if case .failed(let m) = t.state { return m }; return nil }()))
        if t.state == .done {
            batchCount += 1; batchBytes += t.total
            Achievements.shared.recordTransfer(bytes: t.total, label: t.label, resumed: t.attempts > 0)
        }
        if !hasActiveTransfers { Thumbnails.shared.resume() }
        if case .failed = t.state { Mascot.shared.react(.failed) }
        if !transfers.contains(where: { $0.state.isActive }), batchCount > 0 {
            Mascot.shared.react(.done(batchCount))
            Notifier.post(L("Shuttle: готово"), L("Передано: %d · %@", batchCount, formatBytes(batchBytes)))
            batchCount = 0
            batchBytes = 0
        }
    }

    /// A free name in a Mac folder, counting transfers that haven't started yet.
    func reserveTarget(_ dir: URL, _ name: String) -> URL {
        var u = uniqueURL(dir.appendingPathComponent(name))
        var n = 2
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        while reservedTargets.contains(u.path) {
            u = dir.appendingPathComponent(ext.isEmpty ? "\(name) \(n)" : "\(base) \(n).\(ext)")
            u = uniqueURL(u)
            n += 1
        }
        reservedTargets.insert(u.path)
        return u
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
    }

    func show(_ error: Error) {
        if let e = error as? MTPError, e == .cancelled { return }
        errorMessage = error.localizedDescription
    }

    func toast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    #if DEBUG
    /// For screenshots: put folder contents in place without a device.
    func previewSet(_ key: FolderKey, _ items: [RemoteItem]) { cache[key] = items }
    /// For screenshots: tabs for several devices.
    func previewDevices(_ list: [DeviceInfo], selected: Int) {
        devices = list.enumerated().map { DeviceTab(slot: "p\($0.offset)", info: $0.element, service: DeviceService(drivers: [])) }
        selectedSlot = devices[selected].slot
    }
    #endif
}
