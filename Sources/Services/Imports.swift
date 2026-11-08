import Foundation

/// Which device files were already taken to the Mac — for "Download new" and the "already on Mac" badge.
@MainActor
final class ImportLedger: ObservableObject {
    static let shared = ImportLedger()
    /// device → a set of "name|size" keys
    @Published private(set) var seen: [String: Set<String>]
    private let file: JSONFile<[String: Set<String>]>

    init(file: JSONFile<[String: Set<String>]> = JSONFile("imported.json")) {
        self.file = file
        seen = file.load() ?? [:]
    }

    nonisolated static func key(_ name: String, _ size: UInt64) -> String { name.lowercased() + "|" + String(size) }

    func contains(_ item: RemoteItem, device: String) -> Bool {
        seen[device]?.contains(Self.key(item.name, item.size)) ?? false
    }

    func mark(_ items: [RemoteItem], device: String) {
        var s = seen[device] ?? []
        for i in items where !i.isFolder { s.insert(Self.key(i.name, i.size)) }
        seen[device] = s
        file.save(seen)
    }

    func reset(device: String) {
        seen[device] = nil
        file.save(seen)
    }
}

/// Finding duplicates: which device files already sit in a Mac folder (by name and size).
enum Duplicates {
    static func localIndex(_ dir: URL, recursive: Bool = true) -> Set<String> {
        var out = Set<String>()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if recursive, let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true {
                    out.insert(ImportLedger.key(u.lastPathComponent, UInt64(v?.fileSize ?? 0)))
                    // After HEIC → JPG conversion we also compare by the original name.
                    if u.pathExtension.lowercased() == "jpg" {
                        out.insert("heic-base|" + u.deletingPathExtension().lastPathComponent.lowercased())
                    }
                }
            }
        } else if let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for u in urls {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { out.insert(ImportLedger.key(u.lastPathComponent, UInt64(v?.fileSize ?? 0))) }
            }
        }
        return out
    }

    static func isOnMac(_ item: RemoteItem, index: Set<String>) -> Bool {
        guard !item.isFolder else { return false }
        if index.contains(ImportLedger.key(item.name, item.size)) { return true }
        if (item.name as NSString).pathExtension.lowercased() == "heic" {
            return index.contains("heic-base|" + (item.name as NSString).deletingPathExtension.lowercased())
        }
        return false
    }
}

/// Photos and videos: what counts as "camera shots".
enum MediaKind {
    static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng", "raw"]
    static let videos: Set<String> = ["mp4", "mov", "3gp", "mkv", "webm"]

    static func isImage(_ name: String) -> Bool { images.contains((name as NSString).pathExtension.lowercased()) }
    static func isVideo(_ name: String) -> Bool { videos.contains((name as NSString).pathExtension.lowercased()) }
    static func isMedia(_ name: String) -> Bool { isImage(name) || isVideo(name) }
}
