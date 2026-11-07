import Foundation

/// Одна передача в очереди. Прогресс приходит с очереди MTP,
/// а @Published меняются только на главном потоке.
final class Transfer: ObservableObject, Identifiable {
    enum Direction { case toMac, toAndroid }
    enum State: Equatable {
        case queued, running, done, failed(String), cancelled
        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }

    let id = UUID()
    let name: String
    let direction: Direction
    let token = CancelToken()

    @Published var state: State = .queued
    @Published var sent: UInt64 = 0
    @Published var total: UInt64 = 0
    @Published var bytesPerSecond: Double = 0
    /// Куда легло на Mac, чтобы показать в Finder.
    @Published var resultURL: URL?

    private var startedAt: Date?
    private var lastReport = Date.distantPast // трогается только с очереди MTP

    init(name: String, direction: Direction) {
        self.name = name
        self.direction = direction
    }

    var fraction: Double { total == 0 ? 0 : Double(sent) / Double(total) }

    /// Вызывается с очереди MTP.
    func began() {
        DispatchQueue.main.async {
            self.state = .running
            self.startedAt = Date()
        }
    }

    /// Вызывается с очереди MTP; не чаще 10 раз в секунду.
    func report(_ sent: UInt64, _ total: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 || sent == total else { return }
        lastReport = now
        DispatchQueue.main.async {
            self.sent = sent
            self.total = total
            if let s = self.startedAt {
                let dt = now.timeIntervalSince(s)
                if dt > 0.3 { self.bytesPerSecond = Double(sent) / dt }
            }
        }
    }

    @MainActor
    func finish(_ error: Error?) {
        if let e = error as? MTPError, e == .cancelled {
            state = .cancelled
        } else if let error {
            state = .failed(error.localizedDescription)
        } else {
            sent = max(sent, total)
            state = .done
        }
    }

    func cancel() { token.cancel() }
}
