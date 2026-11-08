#if DEBUG
import SwiftUI
import AppKit

/// Debug:
/// `Shuttle --snapshot out.png [dark|light] [phone|switch] [nomac]` — the window with test data;
/// `Shuttle --icon out.png` — a 1024×1024 icon.
enum Snapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let j = args.firstIndex(of: "--icon"), j + 1 < args.count {
            let r = ImageRenderer(content: AppIconView())
            r.scale = 1
            if let cg = r.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[j + 1]))
            }
            exit(0)
        }
        if let j = args.firstIndex(of: "--dmg-background"), j + 1 < args.count {
            // --dmg-background out.png [scale]
            let r = ImageRenderer(content: DMGBackground())
            r.scale = args.count > j + 2 ? CGFloat(Double(args[j + 2]) ?? 1) : 1
            if let cg = r.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                rep.size = DMGBackground.size // size in points at 72 dpi, so @2x is Retina
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[j + 1]))
            }
            exit(0)
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let dark = !args.contains("light")
        let s = AppState(preview: true)
        if args.contains("switch") { fillSwitch(s) } else { fillPhone(s) }
        if args.contains("nomac") { UserDefaults.standard.set(false, forKey: "showMacPane") }
        else { UserDefaults.standard.set(true, forKey: "showMacPane") }

        let day: TimeInterval = 86_400
        if !args.contains("switch") {
            // Phone: the Mac photos folder on the left, camera shots at the bottom.
            s.macURL = URL(fileURLWithPath: NSHomeDirectory() + "/Pictures/Shuttle/HUAWEI nova 9")
            s.macItems = [
                LocalItem(url: URL(fileURLWithPath: "/p1"), name: "Отпуск 2026", size: 0, modified: .now - 30 * day, isFolder: true),
                LocalItem(url: URL(fileURLWithPath: "/p2"), name: "IMG_2031.jpg", size: 3_800_000, modified: .now - 2 * day, isFolder: false),
                LocalItem(url: URL(fileURLWithPath: "/p3"), name: "IMG_2032.jpg", size: 4_100_000, modified: .now - 2 * day, isFolder: false),
                LocalItem(url: URL(fileURLWithPath: "/p4"), name: "IMG_2038.jpg", size: 3_600_000, modified: .now - day, isFolder: false),
                LocalItem(url: URL(fileURLWithPath: "/p5"), name: "VID_0811.mp4", size: 148_000_000, modified: .now - day, isFolder: false),
            ]
            let t1 = Transfer(name: "VID_0815.mp4", direction: .toMac, label: L("Новое видео"))
            t1.state = .running; t1.sent = 193_000_000; t1.total = 312_000_000; t1.bytesPerSecond = 31_000_000
            let t2 = Transfer(name: "IMG_2041.jpg", direction: .toMac, label: L("Новое фото"))
            t2.state = .done; t2.sent = 4_200_000; t2.total = 4_200_000; t2.verified = true
            s.transfers = [t1, t2]
        } else {
        s.macURL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        s.macItems = [
            LocalItem(url: URL(fileURLWithPath: "/a"), name: "Homebrew", size: 0, modified: .now - 3 * day, isFolder: true),
            LocalItem(url: URL(fileURLWithPath: "/b"), name: "atmosphere-1.9.5.zip", size: 6_200_000, modified: .now - 2 * day, isFolder: false),
            LocalItem(url: URL(fileURLWithPath: "/c"), name: "hekate_ctcaer_6.0.7.zip", size: 3_100_000, modified: .now - 2 * day, isFolder: false),
            LocalItem(url: URL(fileURLWithPath: "/d"), name: "DBI.nro", size: 9_400_000, modified: .now - 600, isFolder: false),
            LocalItem(url: URL(fileURLWithPath: "/e"), name: "sys-clk.zip", size: 410_000, modified: .now - 40 * day, isFolder: false),
        ]
        let t1 = Transfer(name: "atmosphere-1.9.5.zip", direction: .toAndroid)
        t1.state = .running; t1.sent = 3_900_000; t1.total = 6_200_000; t1.bytesPerSecond = 31_000_000
        let t2 = Transfer(name: "DBI.nro", direction: .toAndroid)
        t2.state = .done; t2.sent = 9_400_000; t2.total = 9_400_000; t2.verified = true
        s.transfers = [t1, t2]
        }
        if args.contains("multi"), let cur = s.device {
            let other = cur.kind == .console
                ? DeviceInfo(name: "HUAWEI nova 9", kind: .phone, storages: [], battery: 72)
                : DeviceInfo(name: "Nintendo Switch", kind: .console, storages: [], battery: nil)
            s.previewDevices(cur.kind == .console ? [other, cur] : [cur, other], selected: cur.kind == .console ? 1 : 0)
        }

        let updates = UpdateModel(start: false)
        let info = UpdateInfo(version: "0.3.1", size: 4_100_000, notes: [
            "Автообновления: Shuttle сам предложит новую версию",
            "Настройки (⌘,) — галки обновлений и тема",
            "Красивое окно DMG",
        ])
        if args.contains("update") { updates.phase = .found(info) }
        if args.contains("downloading") { updates.phase = .downloading(received: 2_600_000, total: 4_100_000) }
        if args.contains("installed") { updates.phase = .installed("0.3.1") }
        if args.contains("settings") {
            updates.resetSkipped()
            let v = ThemedRoot(theme: dark ? .dark : .light) { SettingsView(startTab: args.contains("badges") ? 3 : 0) }
                .environmentObject(updates).environment(\.isSnapshot, true)
            let r = ImageRenderer(content: v)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: out)
            }
            exit(0)
        }
        let view = ThemedRoot(theme: dark ? .dark : .light) {
                ContentView().overlay { UpdateOverlay() }
            }
            .environmentObject(s)
            .environmentObject(updates)
            .environment(\.isSnapshot, true)
            .frame(width: 1040, height: 700)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
        }
        exit(0)
    }

    private static func item(_ id: UInt32, _ parent: UInt32, _ name: String, _ size: UInt64 = 0, folder: Bool = false) -> RemoteItem {
        RemoteItem(id: id, parentID: parent, storageID: 1, name: name, size: size,
                   modified: Date(timeIntervalSince1970: 0), isFolder: folder)
    }

    @MainActor
    private static func fillSwitch(_ s: AppState) {
        let names = ["SD Card", "Nand USER", "Nand SYSTEM", "Installed games", "SD Card install",
                     "NAND install", "Saves", "Album", "Gamecard"]
        let storages = names.enumerated().map { i, n in
            StorageInfo(id: UInt32(i + 1), name: n,
                        capacity: i == 0 ? 256_000_000_000 : 0, free: i == 0 ? 141_000_000_000 : 0)
        }
        s.connection = .connected(DeviceInfo(name: "Nintendo Switch", kind: .console, storages: storages, battery: nil))
        s.storageID = 1
        s.androidPath = [Crumb(id: mtpRoot, name: "SD Card")]
        s.previewSet(FolderKey(storage: 1, folder: mtpRoot), [
            item(1, 0, ".overlays", folder: true), item(2, 0, "atmosphere", folder: true),
            item(3, 0, "bootloader", folder: true), item(4, 0, "config", folder: true),
            item(5, 0, "games", folder: true), item(6, 0, "Nintendo", folder: true),
            item(7, 0, "switch", folder: true),
            item(20, 0, "boot.dat", 11_000), item(21, 0, "boot.ini", 29),
            item(22, 0, "exosphere.ini", 2_000), item(23, 0, "hbmenu.nro", 1_600_000),
            item(24, 0, "hekate_ctcaer_6.0.7.bin", 107_000), item(25, 0, "payload.bin", 107_000),
        ])
        s.previewSet(FolderKey(storage: 1, folder: 2), [
            item(30, 2, "contents", folder: true), item(31, 2, "config", folder: true),
            item(32, 2, "package3", 8_400_000), item(33, 2, "stratosphere.romfs", 1_900_000),
        ])
        s.expanded = [FolderKey(storage: 1, folder: 2)]
        s.androidSelection = [23]
    }

    @MainActor
    private static func fillPhone(_ s: AppState) {
        s.connection = .connected(DeviceInfo(name: "HUAWEI nova 9", kind: .phone,
            storages: [StorageInfo(id: 1, name: "Внутренняя память", capacity: 113_000_000_000, free: 17_400_000_000)],
            battery: 72))
        s.storageID = 1
        s.androidPath = [Crumb(id: mtpRoot, name: "Внутренняя память"), Crumb(id: 1, name: "DCIM"), Crumb(id: 2, name: "Camera")]
        s.activeQuick = "camera"
        let now = Date()
        s.previewSet(FolderKey(storage: 1, folder: 2), [
            RemoteItem(id: 10, parentID: 2, storageID: 1, name: "Отпуск 2026", size: 0, modified: now - 86_400 * 30, isFolder: true),
            RemoteItem(id: 11, parentID: 2, storageID: 1, name: "IMG_2041.jpg", size: 4_200_000, modified: now - 3_600, isFolder: false),
            RemoteItem(id: 12, parentID: 2, storageID: 1, name: "IMG_2042.jpg", size: 3_900_000, modified: now - 3_000, isFolder: false),
            RemoteItem(id: 13, parentID: 2, storageID: 1, name: "VID_0815.mp4", size: 312_000_000, modified: now - 86_400 * 2, isFolder: false),
        ])
        s.androidSelection = [12]
    }
}
#endif
