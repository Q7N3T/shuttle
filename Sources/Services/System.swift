import Foundation
import AppKit
import Quartz
import UserNotifications
import Photos

// MARK: - Уведомления

@MainActor
enum Notifier {
    private static var asked = false

    static func prepare() {
        guard !asked, !AppFolders.testing else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Только если Shuttle не на переднем плане — иначе и так видно.
    static func post(_ title: String, _ body: String) {
        guard AppSettings.shared.notifications, !NSApp.isActive, !AppFolders.testing else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Быстрый просмотр

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

/// Временная папка для файлов, которые открываем с устройства (просмотр, превью).
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

// MARK: - Фото

enum PhotosExport {
    /// Добавить фото и видео в «Фото».
    static func add(_ urls: [URL]) async throws -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw MTPError.failed("Разрешите Shuttle добавлять фото: Настройки → Конфиденциальность → Фото")
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

// MARK: - Превью

/// Миниатюры: из устройства (если умеет), иначе скачиваем небольшие картинки в кэш.
@MainActor
final class Thumbnails: ObservableObject {
    static let shared = Thumbnails()
    @Published private(set) var images: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []
    static let maxDownload: UInt64 = 15_000_000

    func key(_ item: RemoteItem, _ device: String) -> String { "\(device)#\(item.id)#\(item.size)" }

    func image(for item: RemoteItem, device: String) -> NSImage? { images[key(item, device)] }

    func request(_ item: RemoteItem, device: String, busy: Bool) {
        let k = key(item, device)
        guard images[k] == nil, !pending.contains(k), !failed.contains(k),
              MediaKind.isImage(item.name), AppSettings.shared.thumbnails else { return }
        // Диск-кэш
        let disk = AppFolders.caches.appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let file = disk.appendingPathComponent(k.replacingOccurrences(of: "/", with: "_") + ".jpg")
        if let d = try? Data(contentsOf: file), let img = NSImage(data: d) {
            images[k] = img
            return
        }
        guard !busy else { return } // во время передач очередь занята — не мешаем
        pending.insert(k)
        Task {
            let data: Data? = try? await DeviceService.shared.run { svc in
                if let t = svc.thumbnail(item) { return t }
                guard item.size <= Thumbnails.maxDownload else { return nil }
                let tmp = PreviewCache.url(for: item, device: device)
                if localSize(tmp) != item.size {
                    _ = try svc.downloadTree(item, into: tmp.deletingLastPathComponent(), token: CancelToken(),
                                             resumeInto: tmp) { _, _ in }
                }
                return try? Data(contentsOf: tmp)
            }
            pending.remove(k)
            if let data, let img = ImageConvert.downsample(data) {
                images[k] = img
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                    try? jpg.write(to: file)
                }
            } else {
                failed.insert(k)
            }
        }
    }
}
