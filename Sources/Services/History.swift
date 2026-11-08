import Foundation

/// A history entry: what was copied, where and when.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var name: String
    var toMac: Bool
    var bytes: UInt64
    var device: String
    /// Where the result is on the Mac (for "Show in Finder").
    var macPath: String?
    var ok: Bool
    var note: String?
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 500

    @Published private(set) var entries: [HistoryEntry]
    private let file: JSONFile<[HistoryEntry]>

    init(file: JSONFile<[HistoryEntry]> = JSONFile("history.json")) {
        self.file = file
        entries = file.load() ?? []
    }

    func add(_ e: HistoryEntry) {
        entries.insert(e, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        file.save(entries)
    }

    func clear() {
        entries = []
        file.save(entries)
    }

    /// Totals per day for the list headers.
    var grouped: [(day: Date, items: [HistoryEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }
}
