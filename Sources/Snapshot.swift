#if DEBUG
import SwiftUI
import AppKit

/// Отладка: `Shuttle --snapshot out.png [dark|light]` рисует окно с тестовыми данными.
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
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let dark = !(args.count > i + 2 && args[i + 2] == "light")

        let s = AppState(preview: true)
        s.connection = .connected(DeviceInfo(name: "Pixel 9 Pro", storageID: 1, storageName: "Внутренняя память",
                                             capacity: 256_000_000_000, free: 84_000_000_000, battery: 72))
        s.androidPath = [Crumb(id: mtpRoot, name: "Внутренняя память"), Crumb(id: 1, name: "DCIM"), Crumb(id: 2, name: "Camera")]
        s.activeQuick = "camera"
        s.androidItems = [
            RemoteItem(id: 10, parentID: 2, storageID: 1, name: "Отпуск 2026", size: 0, modified: .now, isFolder: true),
            RemoteItem(id: 11, parentID: 2, storageID: 1, name: "IMG_2041.jpg", size: 4_200_000, modified: .now, isFolder: false),
            RemoteItem(id: 12, parentID: 2, storageID: 1, name: "IMG_2042.jpg", size: 3_900_000, modified: .now, isFolder: false),
            RemoteItem(id: 13, parentID: 2, storageID: 1, name: "VID_0815.mp4", size: 312_000_000, modified: .now, isFolder: false),
        ]
        s.androidSelection = [12]
        s.macURL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        s.macItems = [
            LocalItem(url: URL(fileURLWithPath: "/a"), name: "Проекты", size: 0, isFolder: true),
            LocalItem(url: URL(fileURLWithPath: "/b"), name: "Отчёт_Q3.pdf", size: 2_400_000, isFolder: false),
            LocalItem(url: URL(fileURLWithPath: "/c"), name: "Playlist.mp3", size: 8_100_000, isFolder: false),
            LocalItem(url: URL(fileURLWithPath: "/d"), name: "Проект.zip", size: 146_000_000, isFolder: false),
        ]
        let t1 = Transfer(name: "VID_0815.mp4", direction: .toMac)
        t1.state = .running; t1.sent = 190_000_000; t1.total = 312_000_000; t1.bytesPerSecond = 38_000_000
        let t2 = Transfer(name: "Отчёт_Q3.pdf", direction: .toAndroid)
        t2.state = .done; t2.sent = 2_400_000; t2.total = 2_400_000
        s.transfers = [t1, t2]

        let view = ThemedRoot(theme: dark ? .dark : .light) { ContentView() }
            .environmentObject(s)
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
}
#endif
