import XCTest
@testable import Shuttle

/// Новое в 0.5: несколько устройств сразу, сверка после копирования, «освободить место», достижения.
@MainActor
final class FeatureTests: XCTestCase {
    func waitUntil(_ timeout: TimeInterval = 10, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(cond(), "не дождались")
    }

    // MARK: Телефон и Switch одновременно

    func testTwoDevicesAsTabs() async {
        let phone = MockDriver(kind: .phone, speed: 0), sw = MockDriver(kind: .console, speed: 0)
        let state = AppState(services: [DeviceService(drivers: [phone]), DeviceService(drivers: [sw])])
        state.macURL = tempDir("mac2")
        await state.tick()
        XCTAssertEqual(state.devices.count, 2)
        XCTAssertEqual(state.device?.kind, .phone, "первым выбран первый")
        await waitUntil { state.currentKey.map { state.cache[$0] != nil } ?? false }
        let phoneStorage = state.storageID

        // Переключаемся на Switch: другой сервис, свои разделы.
        state.selectDevice(state.devices[1].slot)
        XCTAssertEqual(state.device?.kind, .console)
        XCTAssertEqual(state.currentStorage?.name, "SD Card")
        await waitUntil { state.currentKey.map { state.cache[$0] != nil } ?? false }

        // И обратно: открытое на телефоне вернулось из памяти.
        state.selectDevice(state.devices[0].slot)
        XCTAssertEqual(state.device?.kind, .phone)
        XCTAssertEqual(state.storageID, phoneStorage)

        // Телефон отключили — остаётся Switch, вкладка переключается сама.
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
        // Сразу переключаемся на Switch — скачивание всё равно идёт с телефона.
        state.selectDevice(state.devices[1].slot)
        await waitUntil { state.transfers.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(state.transfers.first?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.macURL.appendingPathComponent(photo.name).path))
    }

    // MARK: Сверка

    func testDownloadAndUploadAreVerified() throws {
        let mock = MockDriver(kind: .phone, speed: 0)
        let svc = DeviceService(drivers: [mock])
        _ = try svc.sync { try $0.connectIfNeeded() }
        let cam = try svc.sync { try $0.resolve(path: ["DCIM", "Camera"], storage: 1) }.last!.id
        let photo = try svc.sync { try $0.list(storage: 1, parent: cam) }.first { !$0.isFolder }!
        let dir = tempDir("verify")
        let token = CancelToken()
        _ = try svc.sync { try $0.downloadTree(photo, into: dir, token: token) { _, _ in } }
        XCTAssertEqual(token.verified, 1, "скачанное сверено по размеру")

        let up = CancelToken()
        let file = dir.appendingPathComponent(photo.name)
        try svc.sync { try $0.uploadTree([file], parent: mtpRoot, storage: 1, token: up, conflict: .replace) { _, _ in } }
        XCTAssertEqual(up.verified, 1, "загруженное сверено: устройство вернуло тот же размер")
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

        // Тот же размер, но один байт другой — уже не копия.
        var data = try Data(contentsOf: copy)
        data[0] ^= 0xFF
        try data.write(to: copy)
        XCTAssertEqual(svc.sync { $0.compare(photo, with: copy) }, .different)

        // Другой размер — тем более.
        try Data([1, 2, 3]).write(to: copy)
        XCTAssertEqual(svc.sync { $0.compare(photo, with: copy) }, .different)
    }

    // MARK: Достижения

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
