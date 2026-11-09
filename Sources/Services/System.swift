import Foundation
import AppKit
import Quartz
import UserNotifications
import Photos

// MARK: - Notifications

@MainActor
enum Notifier {
    private static var asked = false

    static func prepare() {
        guard !asked, !AppFolders.testing else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Only when Wirrow isn't frontmost — otherwise it's visible anyway.
    static func post(_ title: String, _ body: String) {
        guard AppSettings.shared.notifications, !NSApp.isActive, !AppFolders.testing else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Quick Look

final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []

    @MainActor
    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    @MainActor
    static var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    @MainActor
    static func close() { if isVisible { QLPreviewPanel.shared().orderOut(nil) } }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

/// A temp folder for files we open from the device (viewing, thumbnails).
enum PreviewCache {
    static var dir: URL {
        let u = AppFolders.caches.appendingPathComponent("Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func url(for item: RemoteItem, device: String) -> URL {
        let safe = device.replacingOccurrences(of: "/", with: "_")
        let d = dir.appendingPathComponent(safe, isDirectory: true).appendingPathComponent(String(item.id), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(item.name)
    }

    static func clear() { try? FileManager.default.removeItem(at: dir) }
}

// MARK: - Photos

enum PhotosExport {
    /// Add photos and videos to Photos.
    static func add(_ urls: [URL]) async throws -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw MTPError.failed(L("Разрешите Wirrow добавлять фото: Настройки → Конфиденциальность → Фото"))
        }
        let media = urls.filter { MediaKind.isMedia($0.lastPathComponent) }
        try await PHPhotoLibrary.shared().performChanges {
            for u in media {
                if MediaKind.isVideo(u.lastPathComponent) {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: u)
                } else {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: u)
                }
            }
        }
        return media.count
    }
}

// MARK: - Thumbnails

/// Thumbnails: from the device (if it can), and in the grid — small images are downloaded into a cache.
/// The queue is limited: thumbnails must not get in the way of transfers on the device's single queue.
@MainActor
final class Thumbnails: ObservableObject {
    static let shared = Thumbnails()
    @Published private(set) var images: [String: NSImage] = [:]
    private var queued: [(key: String, item: RemoteItem, device: String, download: Bool)] = []
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []
    static let maxDownload: UInt64 = 3_000_000
    static let parallel = 2
    var isBusy: () -> Bool = { false }
    /// A device's service by its key: the thumbnail comes from exactly the device it was requested for.
    var service: (String) -> DeviceService? = { _ in nil }

    func key(_ item: RemoteItem, _ device: String) -> String { "\(device)#\(item.id)#\(item.size)" }

    func image(for item: RemoteItem, device: String) -> NSImage? { images[key(item, device)] }

    private var diskDir: URL {
        let d = AppFolders.caches.appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func diskURL(_ k: String) -> URL { diskDir.appendingPathComponent(k.replacingOccurrences(of: "/", with: "_") + ".jpg") }

    /// `download` — whether the file itself may be downloaded if the device gives no thumbnail (grid only).
    func request(_ item: RemoteItem, device: String, download: Bool) {
        let k = key(item, device)
        guard images[k] == nil, !inFlight.contains(k), !failed.contains(k),
              MediaKind.isImage(item.name), AppSettings.shared.thumbnails else { return }
        if let d = try? Data(contentsOf: diskURL(k)), let img = NSImage(data: d) {
            images[k] = img
            return
        }
        if let i = queued.firstIndex(where: { $0.key == k }) {
            if download && !queued[i].download { queued[i].download = true }
            return
        }
        queued.append((k, item, device, download && item.size <= Self.maxDownload))
        pump()
    }

    /// Transfers are over — continue the postponed thumbnails.
    func resume() { pump() }

    /// Left the folder — thumbnails not shown yet are no longer needed.
    func cancelQueued() { queued.removeAll() }

    private func pump() {
        while inFlight.count < Self.parallel, !queued.isEmpty, !isBusy() {
            // Fresh requests matter more: that's what is on screen now.
            let job = queued.removeLast()
            inFlight.insert(job.key)
            Task { await run(job) }
        }
    }

    private func run(_ job: (key: String, item: RemoteItem, device: String, download: Bool)) async {
        let item = job.item, device = job.device, allow = job.download
        guard let source = service(device) else { inFlight.remove(job.key); return }
        let data: Data? = try? await source.run { svc -> Data? in
            if let t = svc.thumbnail(item) { return t }
            guard allow else { return nil }
            let tmp = PreviewCache.url(for: item, device: device)
            if localSize(tmp) != item.size {
                _ = try svc.downloadTree(item, into: tmp.deletingLastPathComponent(), token: CancelToken(),
                                         resumeInto: tmp) { _, _ in }
            }
            return try? Data(contentsOf: tmp)
        }
        inFlight.remove(job.key)
        if let data, let img = ImageConvert.downsample(data) {
            images[job.key] = img
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                try? jpg.write(to: diskURL(job.key))
            }
        } else if allow {
            failed.insert(job.key)
        }
        pump()
    }
}
