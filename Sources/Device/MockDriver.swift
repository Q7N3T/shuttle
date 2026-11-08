import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An in-memory test device: a phone or a Switch with DBI.
/// Run with `Shuttle --mock-device phone|switch` (Debug), and in automated tests.
final class MockDriver: DeviceDriver {
    enum Kind: String { case phone, console = "switch" }

    static var requestedKind: Kind? { requestedKinds?.first }

    /// `--mock-device phone|switch|both` — one test device or two at once.
    static var requestedKinds: [Kind]? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--mock-device"), i + 1 < a.count else { return nil }
        if a[i + 1] == "both" { return [.phone, .console] }
        return Kind(rawValue: a[i + 1]).map { [$0] }
    }

    struct Node {
        var id: UInt32
        var parent: UInt32
        var storage: UInt32
        var name: String
        var isFolder: Bool
        var data: Data
        var modified: Date
    }

    let transport: Transport = .mock
    let kind: Kind
    var nodes: [UInt32: Node] = [:]
    var storages: [StorageInfo] = []
    private var nextID: UInt32 = 100

    // Test controls
    var connected = true
    var locked = false
    /// Cut the "cable" after this many bytes (within one operation).
    var failAfterBytes: UInt64?
    /// 0 — instant (tests); in the app — like real USB.
    var bytesPerSecond: Double
    var supportsPartialDownload: Bool { true }
    private(set) var log: [String] = []
    private(set) var listCalls = 0

    init(kind: Kind, speed: Double? = nil) {
        self.kind = kind
        bytesPerSecond = speed ?? (MockDriver.requestedKind != nil ? 40_000_000 : 0)
        kind == .phone ? seedPhone() : seedSwitch()
    }

    // MARK: DeviceDriver

    func connectIfNeeded() throws -> DeviceInfo {
        guard connected else { throw MTPError.notConnected }
        if locked { throw MTPError.locked }
        return DeviceInfo(name: kind == .phone ? "Тестовый телефон" : "Nintendo Switch",
                          kind: kind == .phone ? .phone : .console,
                          storages: storages.map { s in
                              StorageInfo(id: s.id, name: s.name, capacity: s.capacity,
                                          free: s.capacity == 0 ? 0 : s.capacity - used(s.id))
                          },
                          battery: kind == .phone ? 64 : nil,
                          serial: "MOCK-\(kind.rawValue.uppercased())", transport: .mock)
    }

    func release() {}

    func list(storage: UInt32, parent: UInt32) throws -> [RemoteItem] {
        try check()
        listCalls += 1
        let p = parent == 0 ? mtpRoot : parent
        return nodes.values.filter { $0.storage == storage && $0.parent == p }.map(item)
    }

    func download(_ item: RemoteItem, to url: URL, offset: UInt64,
                  progress: @escaping (UInt64, UInt64) -> Bool) throws {
        try check()
        guard let n = nodes[item.id] else { throw MTPError.failed("Нет такого файла") }
        log.append("download \(n.name) from \(offset)")
        let fm = FileManager.default
        if offset == 0 || !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: offset == 0 ? 0 : offset)
        try h.seekToEnd()
        try stream(total: UInt64(n.data.count), from: offset, progress: progress) { range in
            h.write(n.data.subdata(in: range))
        }
    }

    @discardableResult
    func upload(_ url: URL, parent: UInt32, storage: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        try check()
        let data = try Data(contentsOf: url)
        if let s = storages.first(where: { $0.id == storage }), s.capacity > 0,
           UInt64(data.count) > s.capacity - used(storage) {
            throw MTPError.failed("На устройстве нет места")
        }
        log.append("upload \(url.lastPathComponent)")
        var received = Data()
        do {
            try stream(total: UInt64(data.count), from: 0, progress: progress) { range in
                received.append(data.subdata(in: range))
            }
        } catch MTPError.interrupted {
            // Like real MTP: a partial file stays on the device.
            _ = add(url.lastPathComponent, parent: parent, storage: storage, data: received)
            throw MTPError.interrupted
        }
        // DBI: a file in an install storage gets "installed" and disappears, and the game shows up in Installed games.
        if let s = storages.first(where: { $0.id == storage }), s.isInstallTarget,
           ["nsp", "nsz", "xci", "xcz"].contains(url.pathExtension.lowercased()),
           let games = storages.first(where: { $0.isInstalledGames }) {
            let title = url.deletingPathExtension().lastPathComponent
            let id = add(title, parent: mtpRoot, storage: games.id, folder: true)
            _ = add("\(title).nca", parent: id, storage: games.id, data: data)
            return id
        }
        return add(url.lastPathComponent, parent: parent, storage: storage, data: data)
    }

    func createFolder(_ name: String, parent: UInt32, storage: UInt32) throws -> UInt32 {
        try check()
        return add(name, parent: parent == 0 ? mtpRoot : parent, storage: storage, folder: true)
    }

    func delete(_ id: UInt32) throws {
        try check()
        guard nodes[id] != nil else { throw MTPError.failed("Нет такого объекта") }
        if nodes.values.contains(where: { $0.parent == id }) { throw MTPError.failed("Папка не пуста") }
        nodes[id] = nil
    }

    func rename(_ id: UInt32, to name: String) throws {
        try check()
        guard nodes[id] != nil else { throw MTPError.failed("Нет такого объекта") }
        nodes[id]?.name = name
    }

    func thumbnail(_ item: RemoteItem) -> Data? {
        guard let n = nodes[item.id], ["jpg", "jpeg"].contains((n.name as NSString).pathExtension.lowercased())
        else { return nil }
        return n.data
    }

    // MARK: Test helpers

    @discardableResult
    func add(_ name: String, parent: UInt32, storage: UInt32, folder: Bool = false,
             data: Data = Data(), modified: Date = Date()) -> UInt32 {
        nextID += 1
        nodes[nextID] = Node(id: nextID, parent: parent, storage: storage, name: name,
                             isFolder: folder, data: data, modified: modified)
        return nextID
    }

    func find(_ path: [String], storage: UInt32) -> Node? {
        var parent = mtpRoot
        var node: Node?
        for name in path {
            node = nodes.values.first { $0.storage == storage && $0.parent == parent && $0.name == name }
            guard let n = node else { return nil }
            parent = n.id
        }
        return node
    }

    func children(of id: UInt32) -> [Node] { nodes.values.filter { $0.parent == id } }

    // MARK: Internals

    func remoteSize(_ id: UInt32) -> UInt64? { nodes[id].map { UInt64($0.data.count) } }

    func readRange(_ item: RemoteItem, offset: UInt64, length: UInt32) -> Data? {
        guard let d = nodes[item.id]?.data, offset < UInt64(d.count) else { return nil }
        let end = min(d.count, Int(offset) + Int(length))
        return d.subdata(in: Int(offset)..<end)
    }

    private func check() throws {
        guard connected else { throw MTPError.interrupted }
    }

    private func item(_ n: Node) -> RemoteItem {
        RemoteItem(id: n.id, parentID: n.parent == mtpRoot ? 0 : n.parent, storageID: n.storage,
                   name: n.name, size: UInt64(n.data.count), modified: n.modified, isFolder: n.isFolder)
    }

    private func used(_ storage: UInt32) -> UInt64 {
        nodes.values.filter { $0.storage == storage }.reduce(0) { $0 + UInt64($1.data.count) } + 9_000_000_000
    }

    /// Transfer in chunks with the given speed, cancellation and drops.
    private func stream(total: UInt64, from start: UInt64, progress: (UInt64, UInt64) -> Bool,
                        write: (Range<Int>) -> Void) throws {
        let chunk = 256 * 1024
        var pos = Int(start)
        var moved: UInt64 = 0
        while pos < Int(total) {
            let end = min(pos + chunk, Int(total))
            if let limit = failAfterBytes, moved + UInt64(end - pos) > limit {
                let cut = pos + Int(limit - moved)
                if cut > pos { write(pos..<cut) }
                failAfterBytes = nil
                connected = false
                throw MTPError.interrupted
            }
            write(pos..<end)
            moved += UInt64(end - pos)
            pos = end
            if bytesPerSecond > 0 { Thread.sleep(forTimeInterval: Double(chunk) / bytesPerSecond) }
            if !progress(UInt64(pos), total) { throw MTPError.cancelled }
        }
        _ = progress(total, total)
    }

    // MARK: Seeding

    private func seedPhone() {
        storages = [StorageInfo(id: 1, name: "Внутренняя память", capacity: 128_000_000_000, free: 0)]
        let dcim = add("DCIM", parent: mtpRoot, storage: 1, folder: true)
        let cam = add("Camera", parent: dcim, storage: 1, folder: true)
        let day: TimeInterval = 86_400
        for i in 0..<18 {
            add(String(format: "IMG_20261%03d.jpg", 100 + i), parent: cam, storage: 1,
                data: MockDriver.jpeg(seed: i), modified: Date() - Double(18 - i) * day / 3)
        }
        add("IMG_20261200.heic", parent: cam, storage: 1, data: MockDriver.heic(), modified: Date() - 600)
        add("VID_20261101.mp4", parent: cam, storage: 1, data: Data(repeating: 7, count: 3_000_000))
        let trip = add("Отпуск 2026", parent: cam, storage: 1, folder: true)
        for i in 0..<4 { add("trip_\(i).jpg", parent: trip, storage: 1, data: MockDriver.jpeg(seed: 40 + i)) }
        let dl = add("Download", parent: mtpRoot, storage: 1, folder: true)
        add("Договор.pdf", parent: dl, storage: 1, data: Data(repeating: 1, count: 240_000))
        add("app-release.apk", parent: dl, storage: 1, data: Data(repeating: 2, count: 1_200_000))
        let pics = add("Pictures", parent: mtpRoot, storage: 1, folder: true)
        let shots = add("Screenshots", parent: pics, storage: 1, folder: true)
        for i in 0..<3 { add("Screenshot_\(i).jpg", parent: shots, storage: 1, data: MockDriver.jpeg(seed: 60 + i)) }
        _ = add("Movies", parent: mtpRoot, storage: 1, folder: true)
        let music = add("Music", parent: mtpRoot, storage: 1, folder: true)
        add("track.mp3", parent: music, storage: 1, data: Data(repeating: 3, count: 800_000))
        _ = add("Documents", parent: mtpRoot, storage: 1, folder: true)
        _ = add("Android", parent: mtpRoot, storage: 1, folder: true)
        _ = add(".thumbnails", parent: mtpRoot, storage: 1, folder: true)
    }

    private func seedSwitch() {
        let names = ["SD Card", "Nand USER", "Nand SYSTEM", "Installed games", "SD Card install",
                     "NAND install", "Saves", "Album", "Gamecard"]
        storages = names.enumerated().map { i, n in
            StorageInfo(id: UInt32(i + 1), name: n, capacity: i == 0 ? 256_000_000_000 : 0, free: 0)
        }
        // SD Card
        let atm = add("atmosphere", parent: mtpRoot, storage: 1, folder: true)
        add("package3", parent: atm, storage: 1, data: Data(repeating: 9, count: 400_000))
        add("stratosphere.romfs", parent: atm, storage: 1, data: Data(repeating: 8, count: 200_000))
        let cfg = add("config", parent: atm, storage: 1, folder: true)
        add("system_settings.ini", parent: cfg, storage: 1, data: Data("[atmosphere]\n".utf8))
        _ = add("contents", parent: atm, storage: 1, folder: true)
        let bl = add("bootloader", parent: mtpRoot, storage: 1, folder: true)
        _ = add("payloads", parent: bl, storage: 1, folder: true)
        add("hekate_ipl.ini", parent: bl, storage: 1, data: Data("[config]\n".utf8))
        let sw = add("switch", parent: mtpRoot, storage: 1, folder: true)
        let dbi = add("DBI", parent: sw, storage: 1, folder: true)
        add("DBI.nro", parent: dbi, storage: 1, data: Data(repeating: 4, count: 900_000))
        _ = add(".overlays", parent: sw, storage: 1, folder: true)
        _ = add("Nintendo", parent: mtpRoot, storage: 1, folder: true)
        add("hbmenu.nro", parent: mtpRoot, storage: 1, data: Data(repeating: 5, count: 160_000))
        add("boot.ini", parent: mtpRoot, storage: 1, data: Data("[boot]\n".utf8))
        // Installed games (as DBI names them)
        for g in ["Mario Kart 8 Deluxe [0100152000022000][v0]",
                  "The Legend of Zelda Tears of the Kingdom [0100F2C0115B6000][v0]",
                  "Celeste [01002B30028F6000][v0]"] {
            let id = add(g, parent: mtpRoot, storage: 4, folder: true)
            add("\(g).nca", parent: id, storage: 4, data: Data(repeating: 6, count: 120_000))
        }
        // Saves
        for g in ["Mario Kart 8 Deluxe", "Celeste"] {
            let id = add(g, parent: mtpRoot, storage: 7, folder: true)
            let user = add("Игрок 1", parent: id, storage: 7, folder: true)
            add("save.dat", parent: user, storage: 7, data: Data(repeating: 1, count: 64_000))
        }
        // Album
        let album = add("Mario Kart 8 Deluxe", parent: mtpRoot, storage: 8, folder: true)
        for i in 0..<6 {
            add("2026110\(i)1530000-ABCDEF.jpg", parent: album, storage: 8, data: MockDriver.jpeg(seed: 80 + i))
        }
        add("2026110715300000-ABCDEF.mp4", parent: album, storage: 8, data: Data(repeating: 2, count: 900_000))
    }

    /// A small JPEG with a gradient — so thumbnails have something to show.
    static func jpeg(seed: Int, size: CGSize = CGSize(width: 320, height: 240)) -> Data {
        image(seed: seed, size: size, type: UTType.jpeg) ?? Data(repeating: UInt8(seed % 255), count: 30_000)
    }

    static func heic() -> Data {
        image(seed: 7, size: CGSize(width: 640, height: 480), type: UTType.heic) ?? jpeg(seed: 7)
    }

    private static func image(seed: Int, size: CGSize, type: UTType) -> Data? {
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(0.91, 0.73, 0.29), (0.45, 0.32, 0.5), (0.3, 0.6, 0.7),
                                                  (0.85, 0.4, 0.35), (0.4, 0.7, 0.5)]
        let (r, g, b) = hues[seed % hues.count]
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: r, green: g, blue: b, alpha: 1),
                      CGColor(red: 0.09, green: 0.07, blue: 0.1, alpha: 1)] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero,
                                   end: CGPoint(x: size.width, y: size.height * CGFloat(seed % 3 + 1) / 3), options: [])
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        ctx.fillEllipse(in: CGRect(x: CGFloat(seed * 37 % 200), y: 60, width: 90, height: 90))
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
