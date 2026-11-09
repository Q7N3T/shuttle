import XCTest
@testable import Wirrow

/// New in 0.5: several devices at once, verification after copying, free up space, achievements.
@MainActor
final class FeatureTests: XCTestCase {
    func waitUntil(_ timeout: TimeInterval = 10, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(cond(), "timed out waiting")
    }

    // MARK: Phone and Switch at the same time

    func testTwoDevicesAsTabs() async {
        let phone = MockDriver(kind: .phone, speed: 0), sw = MockDriver(kind: .console, speed: 0)
        let state = AppState(services: [DeviceService(drivers: [phone]), DeviceService(drivers: [sw])])
        state.macURL = tempDir("mac2")
        await state.tick()
        XCTAssertEqual(state.devices.count, 2)
        XCTAssertEqual(state.device?.kind, .phone, "the first device is selected first")
        await waitUntil { state.currentKey.map { state.cache[$0] != nil } ?? false }
        let phoneStorage = state.storageID

        // Switch to the Switch: a different service, its own storages.
        state.selectDevice(state.devices[1].slot)
        XCTAssertEqual(state.device?.kind, .console)
        XCTAssertEqual(state.currentStorage?.name, "SD Card")
        await waitUntil { state.currentKey.map { state.cache[$0] != nil } ?? false }

        // And back: what was open on the phone is restored from memory.
        state.selectDevice(state.devices[0].slot)
        XCTAssertEqual(state.device?.kind, .phone)
        XCTAssertEqual(state.storageID, phoneStorage)

        // The phone was unplugged — the Switch remains, the tab switches by itself.
        phone.connected = false
        await state.tick()
        XCTAssertEqual(state.devices.count, 1)
        XCTAssertEqual(state.device?.kind, .console)
    }

    func testTransferStaysOnItsDevice() async {
        let phone = MockDriver(kind: .phone, speed: 0), sw = MockDriver(kind: .console, speed: 0)
        let state = AppState(services: [DeviceService(drivers: [phone]), DeviceService(drivers: [sw])])
        state.macURL = tempDir("mac3")
        await state.tick()
        await waitUntil { state.currentKey.map { state.cache[$0] != nil } ?? false }
        state.openQuick(QuickFolder.android[0])
        await waitUntil { state.androidPath.last?.name == "Camera" && !state.androidRows.isEmpty }
        let photo = state.androidRows.first { $0.item.name.hasSuffix(".jpg") }!.item
        state.download([photo])
        // Switch to the Switch right away — the download still comes from the phone.
        state.selectDevice(state.devices[1].slot)
        await waitUntil { state.transfers.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(state.transfers.first?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.macURL.appendingPathComponent(photo.name).path))
    }

    // MARK: Verification

    func testDownloadAndUploadAreVerified() throws {
        let mock = MockDriver(kind: .phone, speed: 0)
        let svc = DeviceService(drivers: [mock])
        _ = try svc.sync { try $0.connectIfNeeded() }
        let cam = try svc.sync { try $0.resolve(path: ["DCIM", "Camera"], storage: 1) }.last!.id
        let photo = try svc.sync { try $0.list(storage: 1, parent: cam) }.first { !$0.isFolder }!
        let dir = tempDir("verify")
        let token = CancelToken()
        _ = try svc.sync { try $0.downloadTree(photo, into: dir, token: token) { _, _ in } }
        XCTAssertEqual(token.verified, 1, "the download is verified by size")

        let up = CancelToken()
        let file = dir.appendingPathComponent(photo.name)
        try svc.sync { try $0.uploadTree([file], parent: mtpRoot, storage: 1, token: up, conflict: .replace) { _, _ in } }
        XCTAssertEqual(up.verified, 1, "the upload is verified: the device reports the same size")
    }

    func testCompareFindsExactCopiesOnly() throws {
        let mock = MockDriver(kind: .phone, speed: 0)
        let svc = DeviceService(drivers: [mock])
        _ = try svc.sync { try $0.connectIfNeeded() }
        let cam = try svc.sync { try $0.resolve(path: ["DCIM", "Camera"], storage: 1) }.last!.id
        let photo = try svc.sync { try $0.list(storage: 1, parent: cam) }.first { !$0.isFolder }!
        let dir = tempDir("cmp")
        let copy = try svc.sync { try $0.downloadTree(photo, into: dir, token: CancelToken()) { _, _ in } }
        XCTAssertEqual(svc.sync { $0.compare(photo, with: copy) }, .identical)

        // Same size, but one byte differs — no longer a copy.
        var data = try Data(contentsOf: copy)
        data[0] ^= 0xFF
        try data.write(to: copy)
        XCTAssertEqual(svc.sync { $0.compare(photo, with: copy) }, .different)

        // A different size — even more so.
        try Data([1, 2, 3]).write(to: copy)
        XCTAssertEqual(svc.sync { $0.compare(photo, with: copy) }, .different)
    }

    // MARK: Achievements

    func testAchievementsUnlockByThresholds() {
        let a = Achievements.shared
        a.recordTransfer(bytes: 2_000_000_000, label: nil, resumed: true)
        XCTAssertNotNil(a.unlocked["first"])
        XCTAssertNotNil(a.unlocked["gb1"])
        XCTAssertNotNil(a.unlocked["resumed"])
        XCTAssertGreaterThanOrEqual(a.monthBytes, 2_000_000_000)
        XCTAssertNotNil(a.monthJoke)
        XCTAssertEqual(Achievements.cloudPrice(for: 38_000_000_000), "$0.99")
        XCTAssertEqual(Achievements.cloudPrice(for: 150_000_000_000), "$2.99")
    }

    func testUpdateNotesFollowAppLanguage() {
        let html = #"<ul><li>Новый значок</li><li>Сверка</li></ul><div data-lang="en"><p>New icon</p><p>Verification</p></div>"#
        XCTAssertEqual(WirrowUserDriver.notes(from: html, english: false), ["Новый значок", "Сверка"])
        XCTAssertEqual(WirrowUserDriver.notes(from: html, english: true), ["New icon", "Verification"])
        // Old appcast entries — Russian list only.
        XCTAssertEqual(WirrowUserDriver.notes(from: "<ul><li>Только русский</li></ul>", english: true), ["Только русский"])
    }

    func testMascotHatsByDate() {
        func date(_ m: Int, _ d: Int, _ h: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2027, month: m, day: d, hour: h))!
        }
        XCTAssertEqual(Mascot.hat(at: date(11, 7, 14)), .party)
        XCTAssertEqual(Mascot.hat(at: date(12, 31, 14)), .newYear)
        XCTAssertEqual(Mascot.hat(at: date(1, 5, 14)), .newYear)
        XCTAssertEqual(Mascot.hat(at: date(6, 1, 2)), .nightcap)
        XCTAssertEqual(Mascot.hat(at: date(6, 1, 14)), Mascot.Hat.none)
    }
}
