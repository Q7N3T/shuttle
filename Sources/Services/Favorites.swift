import Foundation

/// Избранная папка на устройстве: раздел + путь из имён.
struct FavoriteFolder: Codable, Hashable, Identifiable {
    var id: String { storage + "/" + path.joined(separator: "/") }
    var storage: String
    var path: [String]
    var title: String { path.last ?? storage }
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    @Published private(set) var byDevice: [String: [FavoriteFolder]]
    private let file: JSONFile<[String: [FavoriteFolder]]>

    init(file: JSONFile<[String: [FavoriteFolder]]> = JSONFile("favorites.json")) {
        self.file = file
        byDevice = file.load() ?? [:]
    }

    func list(_ device: String) -> [FavoriteFolder] { byDevice[device] ?? [] }

    func contains(_ f: FavoriteFolder, device: String) -> Bool { list(device).contains(f) }

    func toggle(_ f: FavoriteFolder, device: String) {
        var l = list(device)
        if let i = l.firstIndex(of: f) { l.remove(at: i) } else { l.append(f) }
        byDevice[device] = l
        file.save(byDevice)
    }
}
