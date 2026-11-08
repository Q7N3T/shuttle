import XCTest
@testable import Shuttle

/// Whole-app scenarios: AppState + a test device.
@MainActor
final class AppStateTests: XCTestCase {
    var mock: MockDriver!
    var state: AppState!

    func make(_ kind: MockDriver.Kind) async {
        mock = MockDriver(kind: kind, speed: 0)
        state = AppState(service: DeviceService(drivers: [mock]))
        state.macURL = tempDir("mac")
        state.loadMac()
        await state.tick()
        await waitUntil { self.state.androidPath.count == 1 && self.state.cache[self.state.currentKey!] != nil }
    }

    /// Wait for a condition (transfers run on the device queue).
    func waitUntil(_ timeout: TimeInterval = 10, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(cond(), "timed out waiting")
    }

    /// Open "Camera" and wait for its contents.
    func openCamera() async {
        state.openQuick(QuickFolder.android[0])
        await waitUntil { self.state.androidPath.last?.name == "Camera" && !self.state.androidRows.isEmpty
            && self.state.androidRows.allSatisfy { $0.item.parentID != 0 } }
    }

    func allDone() -> Bool { !state.transfers.isEmpty && state.transfers.allSatisfy { $0.state.isFinished } }

    func testConnectSelectsFirstStorage() async {
        await make(.console)
        XCTAssertEqual(state.device?.kind, .console)
        XCTAssertEqual(state.currentStorage?.name, "SD Card")
        XCTAssertTrue(state.androidRows.contains { $0.item.name == ".overlays" } == false,
                      ".overlays lives in switch/, not at the root")
        XCTAssertTrue(state.androidRows.contains { $0.item.name == "atmosphere" })
    }

    func testHiddenFilesOnPhoneOnly() async {
        await make(.phone)
        state.showHidden = false
        XCTAssertFalse(state.androidRows.contains { $0.item.name == ".thumbnails" })
        state.showHidden = true
        XCTAssertTrue(state.androidRows.contains { $0.item.name == ".thumbnails" })
        state.showHidden = false
    }

    func testDownloadWithHEICConversion() async {
        await make(.phone)
        AppSettings.shared.heicToJPEG = true
        defer { AppSettings.shared.heicToJPEG = false }
        await openCamera()
        let heic = state.androidRows.first { $0.item.name.hasSuffix(".heic") }!.item
        state.download([heic])
        await waitUntil { self.allDone() }
        XCTAssertEqual(state.transfers.first?.state, .done)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: state.macURL.path)) ?? []
        XCTAssertEqual(names, ["IMG_20261200.jpg"])
        XCTAssertTrue(HistoryStore.shared.entries.first?.name.contains("IMG_20261200") ?? false)
    }

    func testSameNameDownloadsDoNotCollide() async {
        await make(.phone)
        await openCamera()
        let jpg = state.androidRows.first { $0.item.name.hasSuffix(".jpg") }!.item
        state.download([jpg, jpg])
        await waitUntil { self.allDone() }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: state.macURL.path)) ?? [])
        XCTAssertEqual(names.count, 2, "\(names)")
    }

    func testInterruptedTransferWaitsAndResumes() async {
        await make(.phone)
        await openCamera()
        let vid = state.androidRows.first { $0.item.name.hasSuffix(".mp4") }!.item
        mock.failAfterBytes = 1_200_000
        state.download([vid])
        await waitUntil { self.state.transfers.first?.state == .waiting }
        // The "cable" is unplugged: the device is gone…
        await state.tick()
        XCTAssertNil(state.device)
        // …and it's back — the transfer continues by itself.
        mock.connected = true
        await state.tick()
        await waitUntil { self.allDone() }
        XCTAssertEqual(state.transfers.first?.state, .done)
        let file = state.macURL.appendingPathComponent(vid.name)
        XCTAssertEqual(try? Data(contentsOf: file), mock.nodes[vid.id]?.data)
        XCTAssertEqual(state.transfers.first?.attempts, 1)
    }

    func testFastReplugStillResumes() async {
        await make(.phone)
        await openCamera()
        let vid = state.androidRows.first { $0.item.name.hasSuffix(".mp4") }!.item
        mock.failAfterBytes = 900_000
        state.download([vid])
        await waitUntil { self.state.transfers.first?.state == .waiting }
        // The cable came back before the next poll: AppState still "sees" the device.
        XCTAssertNotNil(state.device)
        mock.connected = true
        await state.tick()
        await waitUntil { self.allDone() }
        XCTAssertEqual(state.transfers.first?.state, .done)
        XCTAssertEqual(try? Data(contentsOf: state.macURL.appendingPathComponent(vid.name)), mock.nodes[vid.id]?.data)
    }

    func testDropRouting() async {
        await make(.console)
        let d = tempDir()
        let nsp = d.appendingPathComponent("Game [0100000000010000][v0].nsp")
        try? Data(repeating: 1, count: 1000).write(to: nsp)
        state.handleDrop([nsp])
        XCTAssertEqual(state.pendingInstall?.files, [nsp], "a game goes to the install sheet")
        state.pendingInstall = nil
        let zip = d.appendingPathComponent("tool.zip")
        try? Data([0x50, 0x4b]).write(to: zip)
        state.handleDrop([zip])
        XCTAssertEqual(state.pendingHomebrew, zip, "an archive on the SD goes to the homebrew sheet")
    }

    func testAPKOverMTPGoesToDownloads() async {
        await make(.phone)
        let apk = tempDir().appendingPathComponent("app.apk")
        try? Data(repeating: 9, count: 5000).write(to: apk)
        state.handleDrop([apk])
        XCTAssertNil(state.pendingAPK, "can't install over MTP — just copy")
        await waitUntil { self.allDone() }
        XCTAssertNotNil(mock.find(["Download", "app.apk"], storage: 1))
    }

    func testInstallGamesAndSpaceCheck() async {
        await make(.console)
        let nsp = tempDir().appendingPathComponent("Celeste 2 [0100AAAA00000000][v0].nsp")
        try? Data(repeating: 1, count: 200_000).write(to: nsp)
        state.installGames([nsp], toNAND: false)
        await waitUntil { self.allDone() }
        let games = mock.storages.first(where: \.isInstalledGames)!
        XCTAssertTrue(mock.nodes.values.contains { $0.storage == games.id && $0.name.hasPrefix("Celeste 2") })
        XCTAssertNil(state.errorMessage)
    }

    func testNoSpaceBlocksInstall() async {
        await make(.console)
        // The SD card is almost full: 9 GB "used" + files, leave ~50 KB.
        let sdIndex = mock.storages.firstIndex(where: \.isSDCard)!
        let sd = mock.storages[sdIndex]
        let used = 9_000_000_000 + mock.nodes.values.filter { $0.storage == sd.id }.reduce(0) { $0 + UInt64($1.data.count) }
        mock.storages[sdIndex] = StorageInfo(id: sd.id, name: sd.name, capacity: used + 50_000, free: 0)
        await state.refreshDevice()
        let nsp = tempDir().appendingPathComponent("Big [0100BBBB00000000][v0].nsp")
        try? Data(repeating: 1, count: 200_000).write(to: nsp)
        let before = state.transfers.count
        state.installGames([nsp], toNAND: false)
        XCTAssertEqual(state.transfers.count, before, "the transfer doesn't start")
        XCTAssertTrue(state.errorMessage?.contains(formatBytes(200_000)) ?? false, state.errorMessage ?? "no error")
    }

    func testHomebrewInstallReplacesFiles() async {
        await make(.console)
        let src = tempDir()
        write("NEW", src.appendingPathComponent("pack/atmosphere/package3"))
        write("nro", src.appendingPathComponent("pack/Tool.nro"))
        let zip = src.appendingPathComponent("pack.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", src.appendingPathComponent("pack").path, zip.path]
        try? p.run(); p.waitUntilExit()
        state.installHomebrew(zip)
        await waitUntil { self.allDone() }
        XCTAssertEqual(state.transfers.first?.state, .done)
        XCTAssertEqual(mock.find(["atmosphere", "package3"], storage: 1)?.data, Data("NEW".utf8))
        XCTAssertNotNil(mock.find(["switch", "Tool", "Tool.nro"], storage: 1))
        XCTAssertNotNil(mock.find(["atmosphere", "stratosphere.romfs"], storage: 1), "everything else is untouched")
    }

    func testBackupSaves() async {
        await make(.console)
        state.backupSaves()
        await waitUntil { self.allDone() }
        guard let dest = state.transfers.first?.resultURL else { return XCTFail("no folder") }
        let save = dest.appendingPathComponent("Celeste/Игрок 1/save.dat")
        XCTAssertEqual(localSize(save), 64_000)
        try? FileManager.default.removeItem(at: dest)
    }

    func testNewPhotosAndImport() async {
        AppSettings.shared.photosFolder = tempDir("photos")
        await make(.phone)
        ImportLedger.shared.reset(device: state.deviceKey)
        await state.refreshPhotosIndexNow()
        await state.refreshNewPhotos()
        XCTAssertEqual(state.newPhotos.count, 20, "18 jpg + heic + mp4")
        let first = Array(state.newPhotos.prefix(3))
        state.newPhotos = first
        state.importNewPhotos()
        await waitUntil { self.allDone() }
        XCTAssertTrue(first.allSatisfy { ImportLedger.shared.contains($0, device: self.state.deviceKey) })
        await state.refreshNewPhotos()
        XCTAssertEqual(state.newPhotos.count, 17)
        XCTAssertTrue(state.isOnMac(first[0]))
    }

    func testSyncRuleCopiesOnlyNew() async {
        await make(.phone)
        let local = tempDir("sync")
        let rule = SyncRule(device: state.deviceKey, deviceName: "t", storage: "Внутренняя память",
                            path: ["DCIM", "Camera"], localPath: local.path)
        state.runSyncs([rule])
        await waitUntil { self.allDone() }
        XCTAssertEqual(localSize(local.appendingPathComponent("Отпуск 2026/trip_1.jpg")),
                       UInt64(mock.find(["DCIM", "Camera", "Отпуск 2026", "trip_1.jpg"], storage: 1)!.data.count))
        // The second run downloads nothing.
        state.clearFinished()
        let before = mock.log.filter { $0.hasPrefix("download") }.count
        state.runSyncs([rule])
        await waitUntil { self.allDone() }
        XCTAssertEqual(mock.log.filter { $0.hasPrefix("download") }.count, before)
    }

    func testSearchDeep() async {
        await make(.phone)
        state.searchText = "Screenshot"
        state.deepSearch()
        await waitUntil { !self.state.deepSearching }
        XCTAssertEqual(state.deepResults?.count, 4, "the Screenshots folder + 3 files")
        XCTAssertTrue(state.deepResults?.contains { $0.path == "Pictures/Screenshots" } ?? false)
        state.clearSearch()
        XCTAssertNil(state.deepResults)
    }

    func testBatchRenameOnDevice() async {
        await make(.phone)
        await openCamera()
        let jpgs = Array(state.androidRows.map(\.item).filter { $0.name.hasSuffix(".jpg") }.prefix(2))
        state.applyRename(RenameRequest(remote: jpgs), pattern: RenamePattern(template: "Море {n}", start: 1, digits: 2))
        await waitUntil { self.state.androidRows.contains { $0.item.name == "Море 02.jpg" } }
        XCTAssertNotNil(mock.find(["DCIM", "Camera", "Море 01.jpg"], storage: 1))
    }

    func testFavoritesNavigation() async {
        await make(.phone)
        state.open(path: ["Pictures", "Screenshots"])
        await waitUntil { self.state.androidPath.count == 3 }
        let fav = state.currentFavorite!
        XCTAssertEqual(fav.path, ["Pictures", "Screenshots"])
        if !FavoritesStore.shared.contains(fav, device: state.deviceKey) { state.toggleFavorite(fav) }
        state.selectStorage(state.storageID!)
        state.openFavorite(fav)
        await waitUntil { self.state.androidPath.last?.name == "Screenshots" }
        state.toggleFavorite(fav)
    }

    func testDeleteAndCreateFolder() async {
        await make(.phone)
        state.createAndroidFolder("Тест папка")
        await waitUntil { self.state.androidRows.contains { $0.item.name == "Тест папка" } }
        let f = state.androidRows.first { $0.item.name == "Тест папка" }!.item
        state.deleteAndroid([f])
        await waitUntil { !self.state.androidRows.contains { $0.item.name == "Тест папка" } }
    }
}
