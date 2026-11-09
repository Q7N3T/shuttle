import XCTest
@testable import Wirrow

/// The device layer on the test driver.
final class DeviceServiceTests: XCTestCase {
    var mock: MockDriver!
    var svc: DeviceService!

    override func setUp() {
        mock = MockDriver(kind: .phone, speed: 0)
        svc = DeviceService(drivers: [mock])
        _ = try? svc.sync { try $0.connectIfNeeded() }
    }

    private var camera: UInt32 { mock.find(["DCIM", "Camera"], storage: 1)!.id }

    func testConnectAndList() throws {
        let info = try svc.sync { try $0.connectIfNeeded() }
        XCTAssertEqual(info.kind, .phone)
        XCTAssertEqual(info.transport, .mock)
        let root = try svc.sync { try $0.list(storage: 1, parent: mtpRoot) }
        XCTAssertTrue(root.first!.isFolder, "folders first")
        XCTAssertTrue(root.contains { $0.name == "DCIM" })
    }

    func testResolveAndEnsureFolder() throws {
        let crumbs = try svc.sync { try $0.resolve(path: ["dcim", "camera"], storage: 1) }
        XCTAssertEqual(crumbs.map(\.name), ["DCIM", "Camera"])
        let id = try svc.sync { try $0.ensureFolder(path: ["Download", "Новая", "Глубже"], storage: 1) }
        XCTAssertEqual(mock.find(["Download", "Новая", "Глубже"], storage: 1)?.id, id)
        let again = try svc.sync { try $0.ensureFolder(path: ["Download", "Новая", "Глубже"], storage: 1) }
        XCTAssertEqual(id, again, "an existing folder is not created again")
    }

    func testDownloadTreeByteExact() throws {
        let dir = tempDir()
        let trip = mock.find(["DCIM", "Camera", "Отпуск 2026"], storage: 1)!
        let item = try svc.sync { try $0.list(storage: 1, parent: camera) }.first { $0.id == trip.id }!
        let out = try svc.sync { try $0.downloadTree(item, into: dir, token: CancelToken()) { _, _ in } }
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(files, ["trip_0.jpg", "trip_1.jpg", "trip_2.jpg", "trip_3.jpg"])
        let original = mock.children(of: trip.id).first { $0.name == "trip_0.jpg" }!.data
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("trip_0.jpg")), original)
    }

    func testDownloadResumesAfterInterruption() throws {
        let dir = tempDir()
        let vid = try svc.sync { try $0.list(storage: 1, parent: camera) }.first { $0.name.hasSuffix(".mp4") }!
        let target = dir.appendingPathComponent(vid.name)
        mock.failAfterBytes = 1_000_000
        XCTAssertThrowsError(try svc.sync { try $0.downloadTree(vid, into: dir, token: CancelToken(), resumeInto: target) { _, _ in } }) {
            XCTAssertEqual($0 as? MTPError, .interrupted)
        }
        XCTAssertEqual(localSize(target), 1_000_000, "the partial file stays")
        mock.connected = true
        _ = try svc.sync { try $0.connectIfNeeded() }
        _ = try svc.sync { try $0.downloadTree(vid, into: dir, token: CancelToken(), resumeInto: target) { _, _ in } }
        XCTAssertEqual(try Data(contentsOf: target), mock.nodes[vid.id]!.data)
        XCTAssertTrue(mock.log.contains { $0.contains("from 1000000") }, "resumes from where it dropped: \(mock.log)")
    }

    func testCancelRemovesPartialFile() throws {
        let dir = tempDir()
        let vid = try svc.sync { try $0.list(storage: 1, parent: camera) }.first { $0.name.hasSuffix(".mp4") }!
        let token = CancelToken()
        XCTAssertThrowsError(try svc.sync {
            try $0.downloadTree(vid, into: dir, token: token) { s, _ in if s > 500_000 { token.cancel() } }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(vid.name).path))
    }

    func testUploadTreeMergesAndSkipsIdentical() throws {
        let src = tempDir()
        write("one", src.appendingPathComponent("Мой/a.txt"))
        write("two", src.appendingPathComponent("Мой/вложенная/b.txt"))
        let dl = mock.find(["Download"], storage: 1)!.id
        try svc.sync { try $0.uploadTree([src.appendingPathComponent("Мой")], parent: dl, storage: 1, token: CancelToken()) { _, _ in } }
        try svc.sync { try $0.uploadTree([src.appendingPathComponent("Мой")], parent: dl, storage: 1, token: CancelToken()) { _, _ in } }
        let folder = mock.find(["Download", "Мой"], storage: 1)!
        XCTAssertEqual(mock.nodes.values.filter { $0.parent == dl && $0.name == "Мой" }.count, 1, "the folder was merged")
        XCTAssertEqual(mock.children(of: folder.id).filter { $0.name == "a.txt" }.count, 1, "an identical file is not duplicated")
        XCTAssertEqual(mock.find(["Download", "Мой", "вложенная", "b.txt"], storage: 1)?.data, Data("two".utf8))
    }

    func testUploadManyFilesListsFolderOnce() throws {
        let src = tempDir()
        let files = (0..<20).map { i -> URL in
            let u = src.appendingPathComponent("f\(i).txt"); write("\(i)", u); return u
        }
        let dl = mock.find(["Download"], storage: 1)!.id
        let before = mock.listCalls
        try svc.sync { try $0.uploadTree(files, parent: dl, storage: 1, token: CancelToken()) { _, _ in } }
        XCTAssertEqual(mock.listCalls - before, 1, "the destination folder is listed once")
        XCTAssertEqual(mock.children(of: dl).filter { $0.name.hasPrefix("f") }.count, 20)
    }

    func testUploadReplace() throws {
        let src = tempDir()
        let f = src.appendingPathComponent("boot.ini")
        write("[new]", f)
        let s = MockDriver(kind: .console, speed: 0)
        let service = DeviceService(drivers: [s])
        _ = try service.sync { try $0.connectIfNeeded() }
        try service.sync { try $0.uploadTree([f], parent: mtpRoot, storage: 1, token: CancelToken(), conflict: .replace) { _, _ in } }
        let boots = s.nodes.values.filter { $0.storage == 1 && $0.parent == mtpRoot && $0.name == "boot.ini" }
        XCTAssertEqual(boots.count, 1)
        XCTAssertEqual(boots.first?.data, Data("[new]".utf8))
    }

    func testUploadResumeRemovesRemnant() throws {
        let src = tempDir()
        let big = src.appendingPathComponent("big.bin")
        try Data(repeating: 3, count: 2_000_000).write(to: big)
        let dl = mock.find(["Download"], storage: 1)!.id
        mock.failAfterBytes = 700_000
        XCTAssertThrowsError(try svc.sync { try $0.uploadTree([big], parent: dl, storage: 1, token: CancelToken()) { _, _ in } })
        XCTAssertEqual(mock.find(["Download", "big.bin"], storage: 1)?.data.count, 700_000, "a partial file is left on the device")
        mock.connected = true
        _ = try svc.sync { try $0.connectIfNeeded() }
        try svc.sync { try $0.uploadTree([big], parent: dl, storage: 1, token: CancelToken()) { _, _ in } }
        let copies = mock.children(of: dl).filter { $0.name == "big.bin" }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.data.count, 2_000_000)
    }

    func testSearchAndWalk() throws {
        var found: [String] = []
        try svc.sync {
            try $0.search(storage: 1, root: mtpRoot, query: "trip_", token: CancelToken(),
                          found: { i, p in found.append((p + [i.name]).joined(separator: "/")) }, scanned: { _ in })
        }
        XCTAssertEqual(found.count, 4)
        XCTAssertTrue(found.allSatisfy { $0.hasPrefix("DCIM/Camera/Отпуск 2026/") })
        let all = try svc.sync { try $0.walk(storage: 1, root: camera) }
        XCTAssertTrue(all.contains { $0.path == ["Отпуск 2026", "trip_2.jpg"] })
    }

    func testDeleteTree() throws {
        let trip = mock.find(["DCIM", "Camera", "Отпуск 2026"], storage: 1)!
        let item = try svc.sync { try $0.list(storage: 1, parent: camera) }.first { $0.id == trip.id }!
        try svc.sync { try $0.deleteTree(item) }
        XCTAssertNil(mock.find(["DCIM", "Camera", "Отпуск 2026"], storage: 1))
    }

    func testDBIInstallSimulation() throws {
        let s = MockDriver(kind: .console, speed: 0)
        let service = DeviceService(drivers: [s])
        let info = try service.sync { try $0.connectIfNeeded() }
        XCTAssertEqual(info.storages.count, 9)
        let install = info.storage(where: \.isInstallTarget)!
        let games = info.storage(where: \.isInstalledGames)!
        let nsp = tempDir().appendingPathComponent("Hollow Knight [0100633007D48000][v0].nsp")
        try Data(repeating: 1, count: 300_000).write(to: nsp)
        try service.sync { try $0.uploadTree([nsp], parent: mtpRoot, storage: install.id, token: CancelToken()) { _, _ in } }
        let installed = try service.sync { try $0.list(storage: games.id, parent: mtpRoot) }
        XCTAssertTrue(installed.contains { GameName($0.name).title == "Hollow Knight" })
        XCTAssertTrue(try service.sync { try $0.list(storage: install.id, parent: mtpRoot) }.isEmpty)
    }

    func testStorageFlags() {
        let s = StorageInfo(id: 1, name: "SD Card install", capacity: 0, free: 0)
        XCTAssertTrue(s.isInstallTarget)
        XCTAssertFalse(StorageInfo(id: 1, name: "Installed games", capacity: 0, free: 0).isInstallTarget)
        XCTAssertTrue(StorageInfo(id: 1, name: "SD Card", capacity: 0, free: 0).isSDCard)
    }
}
