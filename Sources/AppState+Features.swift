import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Batch rename: what we are renaming.
struct RenameRequest: Identifiable {
    let id = UUID()
    var remote: [RemoteItem] = []
    var local: [LocalItem] = []
    var inputs: [RenamePattern.Input] {
        remote.isEmpty
            ? local.map { .init(name: $0.name, modified: $0.modified, isFolder: $0.isFolder) }
            : remote.map { .init(name: $0.name, modified: $0.modified, isFolder: $0.isFolder) }
    }
}

/// Where the files ended up (learned on the device queue, read after the transfer).
final class DestinationBox: @unchecked Sendable {
    var folder: UInt32?
}

/// Games waiting to be installed, and where.
struct PendingInstall: Identifiable {
    let id = UUID()
    let files: [URL]
    var size: UInt64 { files.reduce(0) { $0 + localSize($1) } }
}

extension AppState {

    // MARK: - Download and upload

    var photosDestination: URL {
        let name = (device?.name ?? L("Устройство")).replacingOccurrences(of: "/", with: "-")
        return AppSettings.shared.photosFolder.appendingPathComponent(name, isDirectory: true)
    }

    func download(_ items: [RemoteItem], to dir: URL? = nil, label: String? = nil,
                  labelFor: ((RemoteItem) -> String)? = nil, markImported: Bool = false,
                  completion: (@MainActor () -> Void)? = nil) {
        let dir = dir ?? macURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let heic = AppSettings.shared.heicToJPEG
        let key = deviceKey
        var left = items.count
        for item in items {
            let target = reserveTarget(dir, item.name)
            let t = Transfer(name: item.name, direction: .toMac, label: labelFor?(item) ?? label, deviceKey: key)
            t.resultURL = target
            run(t, completion: { [weak self] t in
                guard let self else { return }
                if t.state == .done {
                    if markImported { ImportLedger.shared.mark([item], device: key) }
                    if dir == self.macURL { self.loadMac() }
                    self.newPhotos.removeAll { $0.id == item.id }
                }
                left -= 1
                if left == 0 { completion?() }
            }) { svc, t in
                let url = try svc.downloadTree(item, into: dir, token: t.token, resumeInto: target) { t.report($0, $1) }
                if heic { _ = ImageConvert.convertAllHEIC(in: url) }
                return url
            }
        }
    }

    /// Upload to the device. Drops land here too — "special" files are handled here.
    func handleDrop(_ urls: [URL], into folder: RemoteItem? = nil) {
        guard let device, !urls.isEmpty else { return }
        if device.kind == .console {
            let games = urls.filter(GameFiles.isInstallable)
            let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
            if !games.isEmpty, games.count == urls.count, currentStorage?.isInstallTarget != true {
                pendingInstall = PendingInstall(files: games)
                return
            }
            if zips.count == 1, urls.count == 1, currentStorage?.isSDCard == true {
                pendingHomebrew = zips[0]
                return
            }
        } else {
            let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
            if !apks.isEmpty, apks.count == urls.count {
                if device.transport == .adb { pendingAPK = apks; return }
                uploadTo(path: ["Download"], urls: apks, label: "APK") { [weak self] in
                    self?.toast(L("APK в «Загрузках» телефона — откройте его там, чтобы установить"))
                }
                return
            }
        }
        upload(urls, into: folder)
    }

    func upload(_ urls: [URL], into folder: RemoteItem? = nil, conflict: ConflictPolicy = .skipIdentical) {
        guard let current = currentKey, !urls.isEmpty else { return }
        let key = folder.map { FolderKey(storage: $0.storageID, folder: $0.id) } ?? current
        guard checkSpace(urls, storage: key.storage) else { return }
        for url in urls {
            let t = Transfer(name: url.lastPathComponent, direction: .toAndroid, deviceKey: deviceKey)
            run(t, completion: { [weak self] _ in
                Task { await self?.invalidate(key); await self?.refreshDevice() }
            }) { svc, t in
                try svc.uploadTree([url], parent: key.folder, storage: key.storage, token: t.token,
                                   conflict: conflict) { t.report($0, $1) }
                return nil
            }
        }
    }

    /// Upload into a folder by path (created if needed) on the current or given storage.
    func uploadTo(path: [String], urls: [URL], storage: StorageInfo? = nil, label: String? = nil,
                  conflict: ConflictPolicy = .skipIdentical, completion: (@MainActor () -> Void)? = nil) {
        guard let st = storage ?? currentStorage else { return }
        guard checkSpace(urls, storage: st.id) else { return }
        var left = urls.count
        let dest = DestinationBox()
        for url in urls {
            let t = Transfer(name: url.lastPathComponent, direction: .toAndroid, label: label, deviceKey: deviceKey)
            run(t, completion: { [weak self] _ in
                left -= 1
                Task {
                    if let id = dest.folder { await self?.invalidate(FolderKey(storage: st.id, folder: id)) }
                    if left == 0 { await self?.refreshDevice(); completion?() }
                }
            }) { svc, t in
                let parent = try svc.ensureFolder(path: path, storage: st.id)
                dest.folder = parent
                try svc.uploadTree([url], parent: parent, storage: st.id, token: t.token,
                                   conflict: conflict) { t.report($0, $1) }
                return nil
            }
        }
    }

    /// After placing files across several folders (homebrew, Atmosphère): the root and whatever is open.
    private func refreshAfterUpload(storage: UInt32) async {
        await invalidate(FolderKey(storage: storage, folder: mtpRoot))
        if let k = currentKey, k.storage == storage, k.folder != mtpRoot { await invalidate(k) }
        await refreshDevice()
    }

    /// Is there enough space. For Switch install storages we look at the SD card or NAND.
    func checkSpace(_ urls: [URL], storage: UInt32) -> Bool {
        guard let device, let st = device.storages.first(where: { $0.id == storage }) else { return true }
        var target = st
        if st.isInstallTarget {
            let nand = st.name.lowercased().contains("nand")
            target = device.storage { nand ? $0.name.lowercased() == "nand user" : $0.isSDCard } ?? st
        }
        guard target.capacity > 0 else { return true }
        let need = urls.reduce(UInt64(0)) { $0 + localSize($1) }
        if need > target.free {
            show(MTPError.noSpace(needed: need, free: target.free))
            return false
        }
        return true
    }

    // MARK: - Switch

    /// Install games via DBI: files go to the "SD Card install" or "NAND install" storage.
    func installGames(_ files: [URL], toNAND: Bool) {
        guard let device,
              let target = device.storage(where: { $0.isInstallTarget && $0.name.lowercased().contains(toNAND ? "nand" : "sd") })
        else { show(MTPError.failed(L("DBI не показывает раздел установки. Обновите DBI."))); return }
        let games = device.storage(where: \.isInstalledGames)
        uploadTo(path: [], urls: files, storage: target, label: L("Установка")) { [weak self] in
            guard let self else { return }
            if let games { Task { await self.invalidate(FolderKey(storage: games.id, folder: mtpRoot)) } }
            self.toast(L("Игры переданы в DBI"))
        }
    }

    /// Unpack a homebrew archive and lay it out across the SD card folders (replacing old files).
    func installHomebrew(_ zip: URL) {
        guard let sd = device?.storage(where: \.isSDCard) ?? currentStorage else { return }
        let t = Transfer(name: zip.lastPathComponent, direction: .toAndroid, label: "Homebrew", deviceKey: deviceKey)
        run(t, completion: { [weak self] t in
            Task { await self?.refreshAfterUpload(storage: sd.id) }
            if t.state == .done { self?.toast(L("Homebrew установлен на SD-карту")) }
        }) { svc, t in
            let dir = try HomebrewLayout.unzip(zip)
            defer { try? FileManager.default.removeItem(at: dir) }
            try Self.place(HomebrewLayout.plan(unpacked: dir), on: sd.id, svc: svc, t: t)
            return nil
        }
    }

    /// Upload laid-out files with a shared progress.
    nonisolated static func place(_ placements: [HomebrewLayout.Placement], on storage: UInt32,
                                  svc: DeviceService, t: Transfer) throws {
        let total = placements.reduce(UInt64(0)) { $0 + localSize($1.local) }
        var done: UInt64 = 0
        for p in placements {
            let parent = try svc.ensureFolder(path: p.remoteFolder, storage: storage)
            let size = localSize(p.local)
            let base = done
            try svc.uploadTree([p.local], parent: parent, storage: storage, token: t.token, conflict: .replace) { s, _ in
                t.report(base + s, total)
            }
            done += size
        }
        t.report(total, total)
    }

    /// Download every save from the "Saves" storage into a dated folder.
    func backupSaves() {
        guard let saves = device?.storage(where: \.isSaves) else {
            show(MTPError.failed(L("Раздела «Saves» нет. Запустите DBI в режиме MTP."))); return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm"
        let dest = AppFolders.documents(L("Сейвы Switch")).appendingPathComponent(df.string(from: Date()), isDirectory: true)
        let t = Transfer(name: L("Все сейвы"), direction: .toMac, label: L("Резервная копия"), deviceKey: deviceKey)
        t.resultURL = dest
        run(t, completion: { [weak self] t in
            if t.state == .done { self?.toast(L("Сейвы сохранены: %@", dest.lastPathComponent)) }
        }) { svc, t in
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let roots = try svc.list(storage: saves.id, parent: mtpRoot)
            let total = roots.count
            for (i, r) in roots.enumerated() {
                _ = try svc.downloadTree(r, into: dest, token: t.token, resumeInto: dest.appendingPathComponent(r.name)) { _, _ in }
                t.report(UInt64(i + 1), UInt64(max(total, 1)))
            }
            return dest
        }
    }

    func checkAtmosphere() {
        atmosphereChecking = true
        Task {
            defer { atmosphereChecking = false }
            do { atmosphere = try await Atmosphere.latest() } catch { show(error) }
        }
    }

    /// Update Atmosphère: copy the old one to the Mac → download from GitHub → lay out with replacement.
    func updateAtmosphere(_ release: AtmosphereRelease) {
        guard let sd = device?.storage(where: \.isSDCard) else { return }
        let key = deviceKey
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm"
        let backup = AppFolders.documents(L("Резервные копии Switch"))
            .appendingPathComponent(L("%@ до %@", df.string(from: Date()), release.version), isDirectory: true)
        atmosphere = nil
        Task {
            let fetch = Transfer(name: "Atmosphère \(release.version)", direction: .toMac, label: L("Скачивание"), deviceKey: key)
            transfers.insert(fetch, at: 0)
            fetch.state = .running
            let zip: URL, fusee: URL?
            do {
                zip = try await Atmosphere.download(release.zipURL)
                fusee = try await release.fuseeURL.asyncMap { try await Atmosphere.download($0) }
                fetch.finish(nil)
            } catch {
                fetch.finish(error)
                return
            }
            let t = Transfer(name: "Atmosphère \(release.version)", direction: .toAndroid, label: L("Обновление"), deviceKey: key)
            run(t, completion: { [weak self] t in
                Task { await self?.refreshAfterUpload(storage: sd.id) }
                if t.state == .done { self?.toast(L("Atmosphère обновлён. Копия старой версии — в «Документы/Shuttle»")) }
            }) { svc, t in
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
                for name in ["atmosphere", "bootloader"] {
                    if let item = try svc.list(storage: sd.id, parent: mtpRoot).first(where: { $0.isFolder && $0.name == name }) {
                        _ = try svc.downloadTree(item, into: backup, token: t.token,
                                                 resumeInto: backup.appendingPathComponent(name)) { _, _ in }
                    }
                }
                let dir = try HomebrewLayout.unzip(zip)
                defer { try? FileManager.default.removeItem(at: dir) }
                var plan = HomebrewLayout.plan(unpacked: dir)
                if let fusee {
                    let named = dir.appendingPathComponent("fusee.bin")
                    try? FileManager.default.moveItem(at: fusee, to: named)
                    plan.append(.init(local: named, remoteFolder: ["bootloader", "payloads"]))
                }
                try AppState.place(plan, on: sd.id, svc: svc, t: t)
                return backup
            }
        }
    }

    // MARK: - Android

    /// How many shots in "Camera" aren't on the Mac yet.
    func refreshNewPhotos() async {
        guard let device, device.kind == .phone, let st = device.storages.first else { return }
        let key = device.key
        do {
            let items: [RemoteItem] = try await svc.run { svc in
                guard let cam = try svc.resolve(path: ["DCIM", "Camera"], storage: st.id).last else { return [] }
                return try svc.list(storage: st.id, parent: cam.id)
            }
            newPhotos = items.filter {
                !$0.isFolder && MediaKind.isMedia($0.name) && !ImportLedger.shared.contains($0, device: key)
                    && !Duplicates.isOnMac($0, index: photosIndex)
            }
        } catch {
            newPhotos = []
        }
    }

    func importNewPhotos() {
        let items = newPhotos
        guard !items.isEmpty else { return }
        let dest = photosDestination
        download(items, to: dest, labelFor: { MediaKind.isVideo($0.name) ? L("Новое видео") : L("Новое фото") },
                 markImported: true) { [weak self] in
            self?.refreshPhotosIndex()
            self?.toast(L("Сохранено в %@", dest.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
        }
    }

    func installAPK(_ urls: [URL]) {
        for u in urls {
            let t = Transfer(name: u.lastPathComponent, direction: .toAndroid, label: L("Установка"), deviceKey: deviceKey)
            run(t, completion: { [weak self] t in
                if t.state == .done { self?.toast(L("Приложение установлено")) }
            }) { svc, t in
                guard let adb = svc.active as? ADBDriver else { throw MTPError.failed(L("Нужен режим ADB")) }
                t.report(0, 1)
                try adb.install(apk: u)
                t.report(1, 1)
                return nil
            }
        }
    }

    func takeScreenshot() {
        let df = DateFormatter()
        df.dateFormat = L("yyyy-MM-dd 'в' HH.mm.ss")
        let dest = reserveTarget(macURL, L("Снимок экрана %@.png", df.string(from: Date())))
        let t = Transfer(name: dest.lastPathComponent, direction: .toMac, label: L("Снимок"), deviceKey: deviceKey)
        t.resultURL = dest
        run(t, completion: { [weak self] _ in self?.loadMac() }) { svc, t in
            guard let adb = svc.active as? ADBDriver else { throw MTPError.failed(L("Нужен режим ADB")) }
            let png = try adb.screenshot()
            try png.write(to: dest)
            t.report(UInt64(png.count), UInt64(png.count))
            return dest
        }
    }

    // MARK: - Sync

    func addSyncRuleForCurrentFolder() {
        guard let device, let st = currentStorage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Синхронизировать сюда")
        panel.message = L("Куда складывать новые файлы из «%@»", androidPath.last?.name ?? st.name)
        panel.directoryURL = photosDestination.deletingLastPathComponent()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        let rule = SyncRule(device: device.key, deviceName: device.name, storage: st.name,
                            path: currentPathNames, localPath: u.path)
        SyncStore.shared.add(rule)
        runSyncs([rule])
    }

    func runSyncs(_ rules: [SyncRule]) {
        guard let device else { return }
        let heic = AppSettings.shared.heicToJPEG
        for var rule in rules where rule.device == device.key {
            guard let st = device.storages.first(where: { $0.name == rule.storage }) else { continue }
            let root = rule.localURL
            let t = Transfer(name: rule.title, direction: .toMac, label: L("Синхронизация"), deviceKey: device.key)
            t.resultURL = root
            run(t, completion: { [weak self] t in
                if t.state == .done {
                    rule.lastRun = Date()
                    SyncStore.shared.update(rule)
                    self?.refreshPhotosIndex()
                }
            }) { svc, t in
                let folder = try svc.resolve(path: rule.path, storage: st.id).last?.id ?? mtpRoot
                let remote = try svc.walk(storage: st.id, root: folder, token: t.token)
                let todo = SyncPlanner.plan(remote: remote.map { .init(path: $0.path, size: $0.item.size) }, localRoot: root)
                let items = remote.filter { r in todo.contains { $0.path == r.path } }
                let total = items.reduce(UInt64(0)) { $0 + $1.item.size }
                var done: UInt64 = 0
                t.report(0, total)
                for (item, path) in items {
                    let dest = path.dropLast().reduce(root) { $0.appendingPathComponent($1) }
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    let target = dest.appendingPathComponent(item.name)
                    let base = done
                    _ = try svc.downloadTree(item, into: dest, token: t.token, resumeInto: target) { s, _ in
                        t.report(base + s, total)
                    }
                    if heic { _ = ImageConvert.convertAllHEIC(in: target) }
                    done += item.size
                }
                t.report(total, total)
                return root
            }
        }
    }

    // MARK: - Duplicates

    /// Files of the current folder (and expanded ones) that already exist in the chosen Mac folder.
    func findDuplicates() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Сравнить")
        panel.message = L("С какой папкой Mac сравнить (вместе с вложенными)")
        panel.directoryURL = photosDestination
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let rows = androidRows.map(\.item).filter { !$0.isFolder }
        Task.detached(priority: .userInitiated) {
            let idx = Duplicates.localIndex(dir, recursive: true)
            let found = rows.filter { Duplicates.isOnMac($0, index: idx) }
            await MainActor.run {
                self.duplicates = found
                self.showDuplicates = true
            }
        }
    }

    // MARK: - Search

    func clearSearch() {
        searchToken?.cancel()
        searchToken = nil
        searchText = ""
        deepResults = nil
        deepSearching = false
        deepScanned = 0
    }

    /// Search all subfolders of the current one.
    func deepSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let k = currentKey else { return }
        searchToken?.cancel()
        let token = CancelToken()
        searchToken = token
        deepResults = []
        deepSearching = true
        deepScanned = 0
        let base = currentPathNames
        Task {
            do {
                try await svc.run { svc in
                    try svc.search(storage: k.storage, root: k.folder, query: q, token: token, found: { item, path in
                        DispatchQueue.main.async {
                            guard !token.isCancelled else { return }
                            self.deepResults?.append(RemoteRow(item: item, depth: 0,
                                                               path: (base + path).joined(separator: "/")))
                        }
                    }, scanned: { n in DispatchQueue.main.async { if !token.isCancelled { self.deepScanned = n } } })
                }
            } catch {
                if (error as? MTPError) != .cancelled { show(error) }
            }
            if !token.isCancelled { deepSearching = false }
        }
    }

    // MARK: - Quick Look

    func quickLook() {
        if QuickLook.isVisible { QuickLook.close(); return }
        if activeSide == .mac {
            let urls = selectedLocalItems.map(\.url)
            QuickLook.shared.show(urls)
            return
        }
        let items = selectedRemoteItems.filter { !$0.isFolder }.prefix(30)
        guard !items.isEmpty else { return }
        let key = deviceKey
        let big = items.contains { $0.size > 300_000_000 }
        if big { toast(L("Открываем большой файл — придётся немного подождать")) }
        Task {
            do {
                let urls: [URL] = try await svc.run { svc in
                    try items.map { item in
                        let dest = PreviewCache.url(for: item, device: key)
                        if localSize(dest) != item.size {
                            _ = try svc.downloadTree(item, into: dest.deletingLastPathComponent(), token: CancelToken(),
                                                     resumeInto: dest) { _, _ in }
                        }
                        return dest
                    }
                }
                QuickLook.shared.show(urls)
            } catch { show(error) }
        }
    }

    /// Add the selected photos and videos to the Photos app.
    func exportToPhotos(_ items: [RemoteItem]) {
        let media = items.filter { !$0.isFolder && MediaKind.isMedia($0.name) }
        guard !media.isEmpty else { return }
        let key = deviceKey
        let t = Transfer(name: L("Фото: %d", media.count), direction: .toMac, label: L("В «Фото»"), deviceKey: key)
        run(t, completion: { [weak self] t in
            guard t.state == .done else { return }
            Task {
                do {
                    let urls = media.map { PreviewCache.url(for: $0, device: key) }
                    let n = try await PhotosExport.add(urls)
                    self?.toast(L("Добавлено в «Фото»: %d", n))
                } catch { self?.show(error) }
            }
        }) { svc, t in
            let total = media.reduce(UInt64(0)) { $0 + $1.size }
            var done: UInt64 = 0
            for item in media {
                let dest = PreviewCache.url(for: item, device: key)
                let base = done
                if localSize(dest) != item.size {
                    _ = try svc.downloadTree(item, into: dest.deletingLastPathComponent(), token: t.token,
                                             resumeInto: dest) { s, _ in t.report(base + s, total) }
                }
                done += item.size
            }
            return nil
        }
    }

    // MARK: - Batch rename

    func beginBatchRename() {
        switch activeSide {
        case .device where !selectedRemoteItems.isEmpty: renameRequest = RenameRequest(remote: selectedRemoteItems)
        case .mac where !selectedLocalItems.isEmpty: renameRequest = RenameRequest(local: selectedLocalItems)
        default: break
        }
    }

    func applyRename(_ request: RenameRequest, pattern: RenamePattern) {
        let names = pattern.apply(request.inputs)
        if !request.remote.isEmpty {
            let pairs = Array(zip(request.remote, names)).filter { $0.0.name != $0.1 }
            let parents = Set(request.remote.map(parentKey))
            Task {
                do {
                    try await svc.run { svc in for (item, name) in pairs { try svc.rename(item.id, to: name) } }
                    toast(L("Переименовано: %d", pairs.count))
                } catch { show(error) }
                for p in parents { await invalidate(p) }
            }
        } else {
            var n = 0
            for (item, name) in zip(request.local, names) where item.name != name {
                let dest = item.url.deletingLastPathComponent().appendingPathComponent(name)
                do { try FileManager.default.moveItem(at: item.url, to: uniqueURL(dest)); n += 1 } catch { show(error) }
            }
            loadMac()
            toast(L("Переименовано: %d", n))
        }
    }

    // MARK: - Favorites

    var currentFavorite: FavoriteFolder? {
        currentStorage.map { FavoriteFolder(storage: $0.name, path: currentPathNames) }
    }

    func favorite(for item: RemoteItem) -> FavoriteFolder? {
        guard item.isFolder, let st = currentStorage else { return nil }
        if let row = deepResults?.first(where: { $0.item.id == item.id }), let p = row.path {
            return FavoriteFolder(storage: st.name, path: p.split(separator: "/").map(String.init) + [item.name])
        }
        // An expanded subfolder: build the path from the cache.
        var path = [item.name]
        var parent = item.parentID
        while parent != 0, parent != mtpRoot, parent != currentAndroidFolder,
              let p = cache.values.lazy.flatMap({ $0 }).first(where: { $0.id == parent }) {
            path.insert(p.name, at: 0)
            parent = p.parentID
        }
        return FavoriteFolder(storage: st.name, path: currentPathNames + path)
    }

    func toggleFavorite(_ f: FavoriteFolder) {
        FavoritesStore.shared.toggle(f, device: deviceKey)
        objectWillChange.send()
    }

    func openFavorite(_ f: FavoriteFolder) {
        guard let st = device?.storages.first(where: { $0.name == f.storage }) else { return }
        open(path: f.path, storage: st, quick: "fav:" + f.id)
    }

    // MARK: - Menu commands

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
        switch activeSide {
        case .device:
            if selectedRemoteItems.count == 1 { beginRename(selectedRemoteItems[0]) } else { beginBatchRename() }
        case .mac:
            if !selectedLocalItems.isEmpty { beginBatchRename() }
        }
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
        if !selectedLocalItems.isEmpty { handleDrop(selectedLocalItems.map(\.url)) }
    }

    func selectStorage(at index: Int) {
        guard let storages = device?.storages, index < storages.count else { return }
        selectStorage(storages[index].id)
    }

    /// On the Mac we only delete to the Trash — that can be undone.
    func trashMac(_ items: [LocalItem]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.recycle(items.map(\.url)) { _, error in
            Task { @MainActor in
                if let error { self.show(error) }
                self.loadMac()
            }
        }
    }

    // MARK: - Dragging to Finder

    /// Dragging a file from the device straight into Finder:
    /// Finder asks for the file, we download it to a temp folder and hand it over.
    nonisolated func itemProvider(for item: RemoteItem, state: AppState) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        provider.registerObject("shuttle-remote:\(item.id)" as NSString, visibility: .ownProcess)

        guard !item.isFolder else { return provider }
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            let t = Transfer(name: item.name, direction: .toMac)
            Task { @MainActor in state.transfers.insert(t, at: 0) }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Shuttle-\(UUID().uuidString)", isDirectory: true)
            state.svc.runDetached { svc in
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
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let v = self else { return nil }
        return try await f(v)
    }
}
