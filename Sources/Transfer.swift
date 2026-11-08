import Foundation

/// One transfer in the queue. Progress comes from the device queue,
/// while @Published values change only on the main thread.
final class Transfer: ObservableObject, Identifiable {
    enum Direction { case toMac, toAndroid }
    enum State: Equatable {
        case queued, running, done, failed(String), cancelled
        /// The connection dropped — we'll continue when the device returns.
        case waiting
        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
        var isActive: Bool { self == .queued || self == .running }
    }

    let id = UUID()
    let name: String
    let direction: Direction
    /// The label left of the name: "Install", "Sync"…
    let label: String?
    /// Which device it's for: we only continue on that same device.
    let deviceKey: String
    private(set) var token = CancelToken()

    @Published var state: State = .queued
    @Published var sent: UInt64 = 0
    @Published var total: UInt64 = 0
    @Published var bytesPerSecond: Double = 0
    /// Where it landed on the Mac, to show in Finder.
    @Published var resultURL: URL?
    /// Files were verified after copying: sizes match on both ends.
    @Published var verified = false

    /// Run again (after a drop). Set by AppState.
    var restart: (() -> Void)?
    /// How many times it was resumed after a drop.
    var attempts = 0

    private var startedAt: Date?
    private var sentAtStart: UInt64 = 0
    private var lastReport = Date.distantPast // only touched from the device queue

    init(name: String, direction: Direction, label: String? = nil, deviceKey: String = "") {
        self.name = name
        self.direction = direction
        self.label = label
        self.deviceKey = deviceKey
    }

    var fraction: Double { total == 0 ? 0 : Double(sent) / Double(total) }

    /// Called from the device queue.
    func began() {
        DispatchQueue.main.async {
            self.state = .running
            self.startedAt = Date()
            self.sentAtStart = self.sent
        }
    }

    /// Called from the device queue; at most 10 times a second.
    func report(_ sent: UInt64, _ total: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 || sent == total else { return }
        lastReport = now
        DispatchQueue.main.async {
            self.sent = sent
            self.total = total
            if let s = self.startedAt {
                let dt = now.timeIntervalSince(s)
                if dt > 0.3, sent >= self.sentAtStart { self.bytesPerSecond = Double(sent - self.sentAtStart) / dt }
            }
        }
    }

    @MainActor
    func finish(_ error: Error?) {
        if let e = error as? MTPError, e == .cancelled {
            state = .cancelled
        } else if let e = error as? MTPError, e == .interrupted, !token.isCancelled {
            state = .waiting
        } else if let error {
            state = .failed(error.localizedDescription)
        } else {
            sent = max(sent, total)
            verified = token.verified > 0
            state = .done
        }
    }

    /// Before a retry: a new cancel flag.
    @MainActor
    func prepareRetry() {
        token = CancelToken()
        attempts += 1
        state = .queued
    }

    func cancel() {
        token.cancel()
        DispatchQueue.main.async { if self.state == .waiting { self.state = .cancelled } }
    }
}
