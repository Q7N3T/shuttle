import Foundation

/// Правило синхронизации: папка устройства → папка Mac (в одну сторону, только новое).
struct SyncRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var device: String
    var deviceName: String
    var storage: String
    var path: [String]
    var localPath: String
    var enabled = true
    var lastRun: Date?

    var title: String { (path.isEmpty ? storage : path.joined(separator: "/")) }
    var localURL: URL { URL(fileURLWithPath: localPath) }
}

@MainActor
final class SyncStore: ObservableObject {
    static let shared = SyncStore()
    @Published private(set) var rules: [SyncRule]
    private let file: JSONFile<[SyncRule]>

    init(file: JSONFile<[SyncRule]> = JSONFile("sync.json")) {
        self.file = file
        rules = file.load() ?? []
    }

    func rules(for device: String) -> [SyncRule] { rules.filter { $0.device == device } }

    func add(_ r: SyncRule) {
        rules.removeAll { $0.device == r.device && $0.storage == r.storage && $0.path == r.path && $0.localPath == r.localPath }
        rules.append(r)
        file.save(rules)
    }

    func remove(_ r: SyncRule) {
        rules.removeAll { $0.id == r.id }
        file.save(rules)
    }

    func update(_ r: SyncRule) {
        if let i = rules.firstIndex(where: { $0.id == r.id }) { rules[i] = r; file.save(rules) }
    }
}

/// Что скачать: файлы, которых нет на Mac или у которых другой размер.
enum SyncPlanner {
    struct RemoteFile { let path: [String]; let size: UInt64 }

    static func plan(remote: [RemoteFile], localRoot: URL, skipHidden: Bool = true) -> [RemoteFile] {
        let fm = FileManager.default
        return remote.filter { f in
            if skipHidden, f.path.contains(where: { $0.hasPrefix(".") }) { return false }
            let u = f.path.reduce(localRoot) { $0.appendingPathComponent($1) }
            guard fm.fileExists(atPath: u.path) else {
                // Уже сконвертированный HEIC тоже считается скачанным.
                if (u.pathExtension.lowercased() == "heic"),
                   fm.fileExists(atPath: u.deletingPathExtension().appendingPathExtension("jpg").path) { return false }
                return true
            }
            return localSize(u) != f.size
        }
    }
}
