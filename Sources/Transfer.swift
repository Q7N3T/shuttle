import Foundation

/// Одна передача в очереди. Прогресс приходит с очереди устройства,
/// а @Published меняются только на главном потоке.
final class Transfer: ObservableObject, Identifiable {
    enum Direction { case toMac, toAndroid }
    enum State: Equatable {
        case queued, running, done, failed(String), cancelled
        /// Связь прервалась — продолжим, когда устройство вернётся.
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
    /// Подпись слева от имени: «Установка», «Синхронизация»…
    let label: String?
    /// Для какого устройства: продолжаем только на нём же.
    let deviceKey: String
    private(set) var token = CancelToken()

    @Published var state: State = .queued
    @Published var sent: UInt64 = 0
    @Published var total: UInt64 = 0
    @Published var bytesPerSecond: Double = 0
    /// Куда легло на Mac, чтобы показать в Finder.
    @Published var resultURL: URL?

    /// Запустить снова (после обрыва). Задаёт AppState.
    var restart: (() -> Void)?
    /// Сколько раз продолжали после обрыва.
    var attempts = 0

    private var startedAt: Date?
    private var sentAtStart: UInt64 = 0
    private var lastReport = Date.distantPast // трогается только с очереди устройства

    init(name: String, direction: Direction, label: String? = nil, deviceKey: String = "") {
        self.name = name
        self.direction = direction
        self.label = label
        self.deviceKey = deviceKey
    }

    var fraction: Double { total == 0 ? 0 : Double(sent) / Double(total) }

    /// Вызывается с очереди устройства.
    func began() {
        DispatchQueue.main.async {
            self.state = .running
            self.startedAt = Date()
            self.sentAtStart = self.sent
        }
    }

    /// Вызывается с очереди устройства; не чаще 10 раз в секунду.
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
            state = .done
        }
    }

    /// Перед повтором: новый флаг отмены.
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
