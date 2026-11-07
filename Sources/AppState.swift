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

/// Папка на устройстве: раздел + id папки.
struct FolderKey: Hashable {
    let storage: UInt32
    let folder: UInt32
}

/// Строка дерева: элемент и глубина вложенности.
struct RemoteRow: Identifiable {
    let item: RemoteItem
    let depth: Int
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

/// Панель, где последний раз кликали: к ней относятся команды меню.
enum Side { case mac, device }

struct QuickFolder: Identifiable {
    let id: String
    let title: String
    let icon: String
    let path: [String]

    static let android: [QuickFolder] = [
        .init(id: "camera", title: "Камера", icon: "camera", path: ["DCIM", "Camera"]),
        .init(id: "download", title: "Загрузки", icon: "arrow.down.circle", path: ["Download"]),
        .init(id: "pictures", title: "Фото", icon: "photo", path: ["Pictures"]),
        .init(id: "movies", title: "Видео", icon: "film", path: ["Movies"]),
        .init(id: "music", title: "Музыка", icon: "music.note", path: ["Music"]),
        .init(id: "docs", title: "Документы", icon: "doc.text", path: ["Documents"]),
    ]
}

@MainActor
final class AppState: ObservableObject {
    private let mtp = DeviceService.shared

    // Устройство
    @Published var connection: Connection = .searching
    @Published var storageID: UInt32?
    @Published var androidPath: [Crumb] = []
    @Published var androidSelection: Set<UInt32> = []
    @Published var activeQuick: String?
    @Published var expanded: Set<FolderKey> = []
    @Published private(set) var loadingKeys: Set<FolderKey> = []
    /// Кэш списков папок: большие папки MTP отдаёт секундами
    /// (Камера с 600+ фото — около 16 с на Huawei), поэтому повторно не перечитываем.
    @Published private(set) var cache: [FolderKey: [RemoteItem]] = [:]

    // Вид
    @Published var sort = SortOrder()
    @Published var showHidden: Bool = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }

    // Mac
    @Published var macURL: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @Published var macItems: [LocalItem] = []
    @Published var macSelection: Set<URL> = []

    // Очередь
    @Published var transfers: [Transfer] = []
    @Published var errorMessage: String?

    // Диалоги (открываются и из панели, и из строки меню)
    @Published var activeSide: Side = .device
    @Published var askNewFolder = false
    @Published var renaming: RemoteItem?
    @Published var toDelete: [RemoteItem] = []
    @Published var dialogText = ""

    /// Что сейчас тащим из панели устройства внутри приложения.
    var draggingRemote: [RemoteItem] = []

    private var monitor: Task<Void, Never>?

    init(preview: Bool = false) {
        if preview { return }
        loadMac()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Производные

    var device: DeviceInfo? { connection.info }
    var currentStorage: StorageInfo? { device?.storages.first { $0.id == storageID } }
    var currentAndroidFolder: UInt32 { androidPath.last?.id ?? mtpRoot }
    var currentKey: FolderKey? { storageID.map { FolderKey(storage: $0, folder: currentAndroidFolder) } }
    var androidLoading: Bool { currentKey.map(loadingKeys.contains) ?? false }
    var hasActiveTransfers: Bool { transfers.contains { !$0.state.isFinished } }

    /// На телефоне служебные папки с точкой прячем; на Switch они нужны (.overlays).
    var hidesDotFiles: Bool { !showHidden && device?.kind == .phone }

    var androidItems: [RemoteItem] {
        guard let k = currentKey else { return [] }
        return arranged(cache[k] ?? [])
    }

    /// Текущая папка с раскрытыми подпапками, развёрнутая в плоский список.
    var androidRows: [RemoteRow] {
        guard let k = currentKey else { return [] }
        var rows: [RemoteRow] = []
        func add(_ key: FolderKey, depth: Int) {
            for item in arranged(cache[key] ?? []) {
                rows.append(RemoteRow(item: item, depth: depth))
                let child = FolderKey(storage: item.storageID, folder: item.id)
                if item.isFolder, expanded.contains(child), depth < 12 { add(child, depth: depth + 1) }
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

    private func arranged(_ items: [RemoteItem]) -> [RemoteItem] {
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

    // MARK: Подключение

    private func tick() async {
        // Во время передачи очередь MTP занята, лишние запросы не шлём.
        if hasActiveTransfers || !loadingKeys.isEmpty { return }
        let wasConnected = device != nil
        do {
            let info = try await mtp.run { try $0.connectIfNeeded() }
            connection = .connected(info)
            if !wasConnected || !info.storages.contains(where: { $0.id == storageID }) {
                cache = [:]
                expanded = []
                selectStorage(info.storages[0].id)
            }
        } catch let e as MTPError {
            switch e {
            case .busy: connection = .busy
            case .locked: connection = .locked
            default: connection = .searching
            }
            if wasConnected { resetDevice() }
        } catch {
            connection = .searching
        }
    }

    private func resetDevice() {
        cache = [:]
        expanded = []
        storageID = nil
        androidPath = []
        androidSelection = []
    }

    // MARK: Навигация по устройству

    func selectStorage(_ id: UInt32) {
        guard let s = device?.storages.first(where: { $0.id == id }) else { return }
        storageID = id
        androidPath = [Crumb(id: mtpRoot, name: s.name)]
        androidSelection = []
        activeQuick = nil
        Task { await loadAndroid(force: false) }
    }

    private func fetch(_ key: FolderKey, force: Bool) async {
        if !force, cache[key] != nil { return }
        if loadingKeys.contains(key) { return }
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }
        do {
            cache[key] = try await mtp.run { try $0.list(storage: key.storage, parent: key.folder) }
        } catch {
            show(error)
        }
    }

    /// `force: false` — взять из кэша, если папка уже открывалась.
    func loadAndroid(force: Bool = true) async {
        guard let k = currentKey else { return }
        await fetch(k, force: force)
        androidSelection = []
    }

    /// Кнопка «Обновить»: текущая папка и все раскрытые в ней.
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
        androidPath.append(Crumb(id: item.id, name: item.name))
        activeQuick = nil
        Task { await loadAndroid(force: false) }
    }

    func goToCrumb(_ index: Int) {
        guard index < androidPath.count - 1 else { return }
        androidPath = Array(androidPath.prefix(index + 1))
        activeQuick = nil
        Task { await loadAndroid(force: false) }
    }

    func androidUp() {
        if androidPath.count > 1 { goToCrumb(androidPath.count - 2) }
    }

    func openQuick(_ q: QuickFolder) {
        guard let storage = currentStorage else { return }
        activeQuick = q.id
        Task {
            do {
                let crumbs = try await mtp.run { try $0.resolve(path: q.path, storage: storage.id) }
                androidPath = [Crumb(id: mtpRoot, name: storage.name)] + crumbs.map { Crumb(id: $0.id, name: $0.name) }
                await loadAndroid(force: false)
            } catch {
                activeQuick = nil
                show(error)
            }
        }
    }

    private func parentKey(_ item: RemoteItem) -> FolderKey {
        FolderKey(storage: item.storageID, folder: item.parentID == 0 ? mtpRoot : item.parentID)
    }

    /// Перечитать папку после изменения: текущую — всегда, остальные — если уже в кэше.
    private func invalidate(_ key: FolderKey) async {
        if key == currentKey || cache[key] != nil { await fetch(key, force: true) }
    }

    func createAndroidFolder(_ name: String) {
        guard let k = currentKey, !name.isEmpty else { return }
        Task {
            do {
                _ = try await mtp.run { try $0.createFolder(name, parent: k.folder, storage: k.storage) }
            } catch { show(error) }
            await invalidate(k)
        }
    }

    func deleteAndroid(_ items: [RemoteItem]) {
        let parents = Set(items.map(parentKey))
        Task {
            do {
                try await mtp.run { svc in
                    for i in items { try svc.deleteTree(i) }
                }
            } catch { show(error) }
            for p in parents { await invalidate(p) }
            await refreshDevice()
        }
    }

    func renameAndroid(_ item: RemoteItem, to name: String) {
        guard !name.isEmpty, name != item.name else { return }
        Task {
            do { try await mtp.run { try $0.rename(item.id, to: name) } } catch { show(error) }
            await invalidate(parentKey(item))
        }
    }

    func selectedRemote(orItem item: RemoteItem) -> [RemoteItem] {
        guard androidSelection.contains(item.id) else { return [item] }
        return androidRows.map(\.item).filter { androidSelection.contains($0.id) }
    }

    private func refreshDevice() async {
        if let info = try? await mtp.run({ try $0.heartbeat() }) { connection = .connected(info) }
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
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let u = panel.url { setMac(u) }
    }

    func selectedLocal(orItem item: LocalItem) -> [LocalItem] {
        macSelection.contains(item.url) ? macItems.filter { macSelection.contains($0.url) } : [item]
    }

    // MARK: Передачи

    func download(_ items: [RemoteItem], to dir: URL? = nil) {
        let dir = dir ?? macURL
        for item in items {
            let t = Transfer(name: item.name, direction: .toMac)
            transfers.insert(t, at: 0)
            Task {
                do {
                    let url = try await mtp.run { svc in
                        t.began()
                        return try svc.downloadTree(item, into: dir, token: t.token) { t.report($0, $1) }
                    }
                    t.resultURL = url
                    t.finish(nil)
                } catch { t.finish(error) }
                if dir == macURL { loadMac() }
            }
        }
    }

    /// Загрузить на устройство: в текущую папку или в папку, на которую бросили файлы.
    func upload(_ urls: [URL], into folder: RemoteItem? = nil) {
        guard let current = currentKey, !urls.isEmpty else { return }
        let key = folder.map { FolderKey(storage: $0.storageID, folder: $0.id) } ?? current
        for url in urls {
            let t = Transfer(name: url.lastPathComponent, direction: .toAndroid)
            transfers.insert(t, at: 0)
            Task {
                do {
                    try await mtp.run { svc in
                        t.began()
                        try svc.uploadTree([url], parent: key.folder, storage: key.storage, token: t.token) {
                            t.report($0, $1)
                        }
                    }
                    t.finish(nil)
                } catch { t.finish(error) }
                await invalidate(key)
                await refreshDevice()
            }
        }
    }

    /// Перетаскивание файла с устройства прямо в Finder:
    /// Finder просит файл, мы скачиваем его во временную папку и отдаём.
    nonisolated func itemProvider(for item: RemoteItem, state: AppState) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        // Для перетаскивания внутри приложения.
        provider.registerObject("shuttle-remote:\(item.id)" as NSString, visibility: .ownProcess)

        guard !item.isFolder else { return provider }
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            let t = Transfer(name: item.name, direction: .toMac)
            Task { @MainActor in state.transfers.insert(t, at: 0) }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Shuttle-\(UUID().uuidString)", isDirectory: true)
            DeviceService.shared.runDetached { svc in
                t.began()
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = try svc.downloadTree(item, into: dir, token: t.token) { t.report($0, $1) }
                    Task { @MainActor in t.finish(nil) }
                    completion(url, false, nil)
                } catch {
                    Task { @MainActor in t.finish(error) }
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    // MARK: Команды меню

    var selectedRemoteItems: [RemoteItem] { androidRows.map(\.item).filter { androidSelection.contains($0.id) } }
    var selectedLocalItems: [LocalItem] { macItems.filter { macSelection.contains($0.url) } }

    var hasSelection: Bool {
        activeSide == .device ? !androidSelection.isEmpty : !macSelection.isEmpty
    }

    func beginNewFolder() {
        guard device != nil else { return }
        dialogText = ""
        askNewFolder = true
    }

    func beginRename(_ item: RemoteItem) {
        dialogText = item.name
        renaming = item
    }

    func selectAll() {
        switch activeSide {
        case .device: androidSelection = Set(androidRows.map(\.id))
        case .mac: macSelection = Set(macItems.map(\.url))
        }
    }

    func deleteSelected() {
        switch activeSide {
        case .device: if !selectedRemoteItems.isEmpty { toDelete = selectedRemoteItems }
        case .mac: trashMac(selectedLocalItems)
        }
    }

    func renameSelected() {
        guard activeSide == .device, selectedRemoteItems.count == 1 else { return }
        beginRename(selectedRemoteItems[0])
    }

    func openSelected() {
        switch activeSide {
        case .device:
            if let f = selectedRemoteItems.first(where: \.isFolder), selectedRemoteItems.count == 1 { openAndroid(f) }
        case .mac:
            if let f = selectedLocalItems.first, selectedLocalItems.count == 1 { openMac(f) }
        }
    }

    func goUp() {
        activeSide == .device ? androidUp() : macUp()
    }

    func refreshAll() {
        loadMac()
        refreshAndroid()
    }

    func downloadSelected() {
        if !selectedRemoteItems.isEmpty { download(selectedRemoteItems) }
    }

    func uploadSelected() {
        if !selectedLocalItems.isEmpty { upload(selectedLocalItems.map(\.url)) }
    }

    func selectStorage(at index: Int) {
        guard let storages = device?.storages, index < storages.count else { return }
        selectStorage(storages[index].id)
    }

    /// На Mac удаляем только в Корзину — это можно отменить.
    func trashMac(_ items: [LocalItem]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.recycle(items.map(\.url)) { _, error in
            Task { @MainActor in
                if let error { self.show(error) }
                self.loadMac()
            }
        }
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
    }

    func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    #if DEBUG
    /// Для снимков: подложить содержимое папки без устройства.
    func previewSet(_ key: FolderKey, _ items: [RemoteItem]) { cache[key] = items }
    #endif
}
