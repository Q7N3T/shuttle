import XCTest
@testable import Shuttle

/// A temp folder that's removed after the test.
func tempDir(_ name: String = "t") -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ShuttleTests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func write(_ text: String, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.data(using: .utf8)!.write(to: url)
}

final class RenamePatternTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26

    func testNameAndNumberKeepsExtension() {
        let p = RenamePattern(template: "Отпуск {n}", start: 1, digits: 2)
        let out = p.apply([.init(name: "IMG_1.jpg", modified: date, isFolder: false),
                           .init(name: "IMG_2.JPG", modified: date, isFolder: false)])
        XCTAssertEqual(out, ["Отпуск 01.jpg", "Отпуск 02.JPG"])
    }

    func testDateToken() {
        let p = RenamePattern(template: "{date} {name}")
        XCTAssertEqual(p.apply([.init(name: "a.png", modified: date, isFolder: false)]), ["2026-10-26 a.png"])
    }

    func testDuplicatesGetSuffix() {
        let p = RenamePattern(template: "photo")
        let out = p.apply([.init(name: "1.jpg", modified: date, isFolder: false),
                           .init(name: "2.jpg", modified: date, isFolder: false)])
        XCTAssertEqual(out, ["photo.jpg", "photo 2.jpg"])
    }

    func testFoldersHaveNoExtensionAndSlashesAreSafe() {
        let p = RenamePattern(template: "{name}/{n}", start: 7, digits: 1)
        XCTAssertEqual(p.apply([.init(name: "Папка.v2", modified: date, isFolder: true)]), ["Папка.v2-7"])
    }

    func testUnknownDateIsDropped() {
        let p = RenamePattern(template: "{date} {name}")
        XCTAssertEqual(p.apply([.init(name: "x.bin", modified: Date(timeIntervalSince1970: 0), isFolder: false)]), ["x.bin"])
    }
}

final class GameNameTests: XCTestCase {
    func testDBIName() {
        let g = GameName("Mario Kart 8 Deluxe [0100152000022000][v0]")
        XCTAssertEqual(g.title, "Mario Kart 8 Deluxe")
        XCTAssertEqual(g.titleID, "0100152000022000")
        XCTAssertEqual(g.version, "v0")
    }

    func testFileNameWithExtraTags() {
        let g = GameName("Celeste_[01002b30028f6000][v65536][US].nsp")
        XCTAssertEqual(g.title, "Celeste")
        XCTAssertEqual(g.titleID, "01002B30028F6000")
        XCTAssertEqual(g.version, "v65536")
    }

    func testPlainName() {
        let g = GameName("Игрок 1")
        XCTAssertEqual(g.title, "Игрок 1")
        XCTAssertNil(g.titleID)
        XCTAssertFalse(g.hasID)
    }
}

final class HomebrewLayoutTests: XCTestCase {
    func testRootFoldersGoToRoot() {
        let d = tempDir()
        write("x", d.appendingPathComponent("atmosphere/package3"))
        write("x", d.appendingPathComponent("bootloader/hekate_ipl.ini"))
        write("x", d.appendingPathComponent("switch/DBI/DBI.nro"))
        let plan = HomebrewLayout.plan(unpacked: d)
        XCTAssertEqual(Set(plan.map { $0.local.lastPathComponent }), ["atmosphere", "bootloader", "switch"])
        XCTAssertTrue(plan.allSatisfy { $0.remoteFolder.isEmpty })
    }

    func testWrapperFolderIsStripped() {
        let d = tempDir()
        write("x", d.appendingPathComponent("SuperTool-1.2/atmosphere/contents/x/exefs.nsp"))
        write("x", d.appendingPathComponent("SuperTool-1.2/switch/.overlays/tool.ovl"))
        let plan = HomebrewLayout.plan(unpacked: d)
        XCTAssertEqual(Set(plan.map { $0.local.lastPathComponent }), ["atmosphere", "switch"])
    }

    func testLooseFiles() {
        let d = tempDir()
        write("x", d.appendingPathComponent("NX-Shell.nro"))
        write("x", d.appendingPathComponent("sys-clk.ovl"))
        write("x", d.appendingPathComponent("fusee.bin"))
        let plan = Dictionary(uniqueKeysWithValues: HomebrewLayout.plan(unpacked: d).map { ($0.local.lastPathComponent, $0.remoteFolder) })
        XCTAssertEqual(plan["NX-Shell.nro"], ["switch", "NX-Shell"])
        XCTAssertEqual(plan["sys-clk.ovl"], ["switch", ".overlays"])
        XCTAssertEqual(plan["fusee.bin"], ["bootloader", "payloads"])
    }

    func testAtmosphereZipKeepsHbmenuInRoot() {
        let d = tempDir()
        write("x", d.appendingPathComponent("atmosphere/package3"))
        write("x", d.appendingPathComponent("switch/reboot_to_payload.nro"))
        write("x", d.appendingPathComponent("hbmenu.nro"))
        let plan = Dictionary(uniqueKeysWithValues: HomebrewLayout.plan(unpacked: d).map { ($0.local.lastPathComponent, $0.remoteFolder) })
        XCTAssertEqual(plan["hbmenu.nro"], [], "hbmenu.nro must be at the SD root")
        XCTAssertEqual(plan["switch"], [])
        XCTAssertEqual(plan["atmosphere"], [])
    }

    func testLoneHbmenuGoesToRoot() {
        let d = tempDir()
        write("x", d.appendingPathComponent("hbmenu.nro"))
        XCTAssertEqual(HomebrewLayout.plan(unpacked: d).first?.remoteFolder, [])
    }

    func testUnknownFolderWithNROGoesToSwitch() {
        let d = tempDir()
        write("x", d.appendingPathComponent("Goldleaf/Goldleaf.nro"))
        write("x", d.appendingPathComponent("README.md"))
        let plan = Dictionary(uniqueKeysWithValues: HomebrewLayout.plan(unpacked: d).map { ($0.local.lastPathComponent, $0.remoteFolder) })
        XCTAssertEqual(plan["Goldleaf"], ["switch"])
    }

    func testUnzipWithDitto() throws {
        let d = tempDir()
        write("hello", d.appendingPathComponent("src/switch/app/app.nro"))
        let zip = d.appendingPathComponent("a.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", d.appendingPathComponent("src").path, zip.path]
        try p.run(); p.waitUntilExit()
        let out = try HomebrewLayout.unzip(zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("switch/app/app.nro").path))
    }
}

final class SyncPlannerTests: XCTestCase {
    func testOnlyNewOrChanged() {
        let root = tempDir()
        write("12345", root.appendingPathComponent("A/same.jpg"))
        write("1", root.appendingPathComponent("A/changed.jpg"))
        write("x", root.appendingPathComponent("photo.jpg")) // converted HEIC
        let remote: [SyncPlanner.RemoteFile] = [
            .init(path: ["A", "same.jpg"], size: 5),
            .init(path: ["A", "changed.jpg"], size: 99),
            .init(path: ["A", "new.jpg"], size: 3),
            .init(path: ["photo.heic"], size: 10),
            .init(path: [".thumbnails", "x.jpg"], size: 1),
        ]
        let plan = SyncPlanner.plan(remote: remote, localRoot: root).map { $0.path.joined(separator: "/") }
        XCTAssertEqual(Set(plan), ["A/changed.jpg", "A/new.jpg"])
    }
}

final class DuplicatesTests: XCTestCase {
    func testNameSizeAndConvertedHEIC() {
        let d = tempDir()
        write("abc", d.appendingPathComponent("sub/IMG_1.jpg"))
        write("zz", d.appendingPathComponent("IMG_2.jpg"))
        let idx = Duplicates.localIndex(d)
        func item(_ n: String, _ s: UInt64) -> RemoteItem {
            RemoteItem(id: 1, parentID: 0, storageID: 1, name: n, size: s, modified: Date(), isFolder: false)
        }
        XCTAssertTrue(Duplicates.isOnMac(item("img_1.JPG", 3), index: idx))
        XCTAssertFalse(Duplicates.isOnMac(item("IMG_1.jpg", 4), index: idx))
        XCTAssertTrue(Duplicates.isOnMac(item("IMG_2.heic", 999), index: idx))
    }
}

final class ImageConvertTests: XCTestCase {
    func testHEICtoJPEG() throws {
        let d = tempDir()
        let heic = d.appendingPathComponent("IMG.heic")
        try MockDriver.heic().write(to: heic)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: heic.path)
        let jpg = try ImageConvert.heicToJPEG(heic)
        XCTAssertEqual(jpg.lastPathComponent, "IMG.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path))
        XCTAssertNotNil(NSImage(contentsOf: jpg))
        let m = try jpg.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(m?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 1)
    }

    func testDownsample() {
        XCTAssertNotNil(ImageConvert.downsample(MockDriver.jpeg(seed: 1), maxPixel: 64))
    }
}

final class AtmosphereTests: XCTestCase {
    func testParseRelease() throws {
        let json = """
        {"tag_name":"1.9.5","published_at":"2026-10-01T10:00:00Z","html_url":"https://github.com/Atmosphere-NX/Atmosphere/releases/tag/1.9.5",
         "assets":[{"name":"atmosphere-1.9.5-master-abc+hbl-2.4.4+hbmenu-3.6.0.zip","browser_download_url":"https://example.com/a.zip"},
                   {"name":"fusee.bin","browser_download_url":"https://example.com/fusee.bin"}]}
        """.data(using: .utf8)!
        let r = try Atmosphere.parse(json)
        XCTAssertEqual(r.version, "1.9.5")
        XCTAssertEqual(r.zipURL.absoluteString, "https://example.com/a.zip")
        XCTAssertEqual(r.fuseeURL?.lastPathComponent, "fusee.bin")
        XCTAssertNotNil(r.published)
    }

    func testParseWithoutZipFails() {
        let json = #"{"tag_name":"1","assets":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try Atmosphere.parse(json))
    }
}

@MainActor
final class StoresTests: XCTestCase {
    func testHistoryPersistsAndLimits() {
        let file = JSONFile<[HistoryEntry]>("h.json", in: tempDir())
        let h = HistoryStore(file: file)
        for i in 0..<(HistoryStore.limit + 5) {
            h.add(HistoryEntry(date: Date(), name: "f\(i)", toMac: true, bytes: 1, device: "d", macPath: nil, ok: true))
        }
        XCTAssertEqual(h.entries.count, HistoryStore.limit)
        XCTAssertEqual(HistoryStore(file: file).entries.first?.name, "f\(HistoryStore.limit + 4)")
    }

    func testFavoritesToggle() {
        let f = FavoritesStore(file: JSONFile("f.json", in: tempDir()))
        let fav = FavoriteFolder(storage: "SD Card", path: ["switch"])
        f.toggle(fav, device: "x")
        XCTAssertTrue(f.contains(fav, device: "x"))
        f.toggle(fav, device: "x")
        XCTAssertFalse(f.contains(fav, device: "x"))
    }

    func testLedger() {
        let l = ImportLedger(file: JSONFile("i.json", in: tempDir()))
        let it = RemoteItem(id: 1, parentID: 0, storageID: 1, name: "A.jpg", size: 5, modified: Date(), isFolder: false)
        XCTAssertFalse(l.contains(it, device: "d"))
        l.mark([it], device: "d")
        XCTAssertTrue(l.contains(it, device: "d"))
        XCTAssertFalse(l.contains(it, device: "other"))
    }
}

final class FormatTests: XCTestCase {
    func testBytes() {
        XCTAssertTrue(formatBytes(512).hasSuffix("Б") || formatBytes(512).hasSuffix("B"))
        XCTAssertTrue(formatBytes(4_200_000).hasPrefix("4"))
        XCTAssertTrue(formatBytes(141_000_000_000).hasPrefix("141"))
    }
}
