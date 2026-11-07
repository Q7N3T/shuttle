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
    let isFolder: Bool
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

struct QuickFolder: Identifiable {
    let id: String
    let title: String
    let icon: String
    let path: [String]

    static let android: [QuickFolder] = [
        .init(id: "root", title: "Вся память", icon: "internaldrive", path: []),
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
    private let mtp = MTPService.shared

    // Телефон
    @Published var connection: Connection = .searching
    @Published var androidPath: [Crumb] = []
    @Published var androidItems: [RemoteItem] = []
    @Published var androidLoading = false
    @Published var androidSelection: Set<UInt32> = []
    @Published var activeQuick: String? = "root"

    // Mac
    @Published var macURL: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @Published var macItems: [LocalItem] = []
    @Published var macSelection: Set<URL> = []

    // Очередь
    @Published var transfers: [Transfer] = []
    @Published var errorMessage: String?

    /// Что сейчас тащим из панели Android внутри приложения.
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

    var hasActiveTransfers: Bool { transfers.contains { !$0.state.isFinished } }
    var storageID: UInt32? { connection.info?.storageID }
    var currentAndroidFolder: UInt32 { androidPath.last?.id ?? mtpRoot }

    // MARK: Подключение

    private func tick() async {
        // Во время передачи очередь MTP занята, лишние запросы не шлём.
        if hasActiveTransfers || androidLoading { return }
        let wasConnected = connection.info != nil
        do {
            let info = try await mtp.run { try $0.connectIfNeeded() }
            connection = .connected(info)
            if !wasConnected {
                androidCache = [:]
                androidPath = [Crumb(id: mtpRoot, name: info.storageName)]
                activeQuick = "root"
                await loadAndroid()
            }
        } catch let e as MTPError {
            switch e {
            case .busy: connection = .busy
            case .locked: connection = .locked
            default: connection = .searching
            }
            if wasConnected {
                androidCache = [:]
                androidItems = []
                androidPath = []
                androidSelection = []
            }
        } catch {
            connection = .searching
        }
    }

    // MARK: Android

    /// Кэш списков папок: на больших папках MTP отвечает секундами
    /// (Камера с 600+ фото — около 17 с на Huawei), поэтому повторно не перечитываем.
    private var androidCache: [UInt32: [RemoteItem]] = [:]

    /// `force: false` — взять из кэша, если папка уже открывалась.
    func loadAndroid(force: Bool = true) async {
        guard let storage = storageID else { return }
        let folder = currentAndroidFolder
        if !force, let cached = androidCache[folder] {
            androidItems = cached
            androidSelection = []
            return
        }
        androidLoading = true
        defer { androidLoading = false }
        do {
            let items = try await mtp.run { try $0.list(storage: storage, parent: folder) }
                .filter { !$0.name.hasPrefix(".") } // служебные папки вроде .RecycleBinHW
            androidCache[folder] = items
            // Пока грузилось, могли уйти в другую папку.
            guard currentAndroidFolder == folder else { return }
            androidItems = items
            androidSelection = []
        } catch {
            show(error)
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
        activeQuick = index == 0 ? "root" : nil
        Task { await loadAndroid(force: false) }
    }

    func androidUp() {
        if androidPath.count > 1 { goToCrumb(androidPath.count - 2) }
    }

    func openQuick(_ q: QuickFolder) {
        guard let info = connection.info else { return }
        activeQuick = q.id
        Task {
            do {
                let crumbs = try await mtp.run { try $0.resolve(path: q.path, storage: info.storageID) }
                androidPath = [Crumb(id: mtpRoot, name: info.storageName)] + crumbs.map { Crumb(id: $0.id, name: $0.name) }
                await loadAndroid(force: false)
            } catch {
                show(error)
            }
        }
    }

    func createAndroidFolder(_ name: String) {
        guard let storage = storageID, !name.isEmpty else { return }
        let parent = currentAndroidFolder
        Task {
            do {
                _ = try await mtp.run { try $0.createFolder(name, parent: parent, storage: storage) }
                await loadAndroid()
            } catch { show(error) }
        }
    }

    func deleteAndroid(_ items: [RemoteItem]) {
        Task {
            do {
                try await mtp.run { svc in
                    for i in items { try svc.delete(i.id) }
                }
            } catch { show(error) }
            await loadAndroid()
            await refreshDevice()
        }
    }

    func renameAndroid(_ item: RemoteItem, to name: String) {
        guard !name.isEmpty, name != item.name else { return }
        Task {
            do { try await mtp.run { try $0.rename(item.id, to: name) } } catch { show(error) }
            await loadAndroid()
        }
    }

    func selectedRemote(orItem item: RemoteItem) -> [RemoteItem] {
        androidSelection.contains(item.id) ? androidItems.filter { androidSelection.contains($0.id) } : [item]
    }

    private func refreshDevice() async {
        if let info = try? await mtp.run({ try $0.heartbeat() }) { connection = .connected(info) }
    }

    // MARK: Mac

    func loadMac() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: macURL, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        macItems = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return LocalItem(url: u, name: u.lastPathComponent,
                             size: UInt64(v?.fileSize ?? 0), isFolder: v?.isDirectory ?? false)
        }
        .sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        macSelection = macSelection.filter { s in macItems.contains { $0.url == s } }
    }

    func openMac(_ item: LocalItem) {
        if item.isFolder {
            macURL = item.url
            macSelection = []
            loadMac()
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func macUp() {
        let parent = macURL.deletingLastPathComponent()
        guard parent.path != macURL.path else { return }
        macURL = parent
        macSelection = []
        loadMac()
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

    func upload(_ urls: [URL]) {
        guard let storage = storageID, !urls.isEmpty else { return }
        let parent = currentAndroidFolder
        let folderAtStart = androidPath
        for url in urls {
            let t = Transfer(name: url.lastPathComponent, direction: .toAndroid)
            transfers.insert(t, at: 0)
            Task {
                do {
                    try await mtp.run { svc in
                        t.began()
                        try svc.uploadTree([url], parent: parent, storage: storage, token: t.token) { t.report($0, $1) }
                    }
                    t.finish(nil)
                } catch { t.finish(error) }
                if androidPath == folderAtStart { await loadAndroid() }
                await refreshDevice()
            }
        }
    }

    /// Перетаскивание файла с телефона прямо в Finder:
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
            MTPService.shared.runDetached { svc in
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

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
    }

    func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
