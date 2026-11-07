import Foundation
import AppKit
import Sparkle

/// Что сейчас показывает карточка обновления.
enum UpdatePhase: Equatable {
    case hidden
    case checking
    case found(UpdateInfo)
    case downloading(received: UInt64, total: UInt64)
    case extracting(Double)
    case ready(UpdateInfo)
    case installing
    case installed(String)
    case upToDate
    case failed(String)

    /// Для анимации смены содержимого.
    var key: String {
        switch self {
        case .hidden: "hidden"
        case .checking: "checking"
        case .found: "found"
        case .downloading, .extracting: "progress"
        case .ready: "ready"
        case .installing: "installing"
        case .installed: "installed"
        case .upToDate: "upToDate"
        case .failed: "failed"
        }
    }
}

struct UpdateInfo: Equatable {
    let version: String
    let size: UInt64
    let notes: [String]
}

/// Состояние обновлений для интерфейса + настройки.
@MainActor
final class UpdateModel: ObservableObject {
    @Published var phase: UpdatePhase = .hidden
    @Published var automaticallyChecks: Bool {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyInstalls: Bool {
        didSet { updater?.automaticallyDownloadsUpdates = automaticallyInstalls }
    }
    @Published private(set) var hasSkippedVersion = false
    /// Итог последней проверки — показываем в настройках (карточка в окне исчезает сама).
    @Published var lastResult: String?
    @Published var lastResultIsError = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // Ответы Sparkle, которые ждут действия пользователя.
    var choiceReply: ((SPUUserUpdateChoice) -> Void)?
    var cancelDownload: (() -> Void)?
    var acknowledgement: (() -> Void)?
    var userInitiated = false
    var pending: UpdateInfo?

    private var updater: SPUUpdater?
    private var driver: ShuttleUserDriver?
    private let delegate = UpdaterDelegate()

    init(start: Bool = true) {
        automaticallyChecks = true
        automaticallyInstalls = false
        guard start, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let driver = ShuttleUserDriver(model: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        self.driver = driver
        self.updater = updater
        do {
            try updater.start()
            automaticallyChecks = updater.automaticallyChecksForUpdates
            automaticallyInstalls = updater.automaticallyDownloadsUpdates
        } catch {
            NSLog("Shuttle: Sparkle не запустился: \(error.localizedDescription)")
        }
        refreshSkipped()
        #if DEBUG
        // Проверка обновления целиком: --update-feed <url> --auto-accept-update
        if UpdaterDelegate.testFeed != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkNow() }
        }
        #endif
    }

    #if DEBUG
    static let autoAccept = CommandLine.arguments.contains("--auto-accept-update")
    #else
    static let autoAccept = false
    #endif

    var canCheck: Bool { updater?.canCheckForUpdates ?? false }
    var lastCheck: Date? { updater?.lastUpdateCheckDate }

    func checkNow() {
        userInitiated = true
        updater?.checkForUpdates()
    }

    // Кнопки карточки
    func install() { answer(.install) }
    func later() { answer(.dismiss) }
    func skip() {
        answer(.skip)
        refreshSkipped()
    }

    func cancel() {
        cancelDownload?()
        cancelDownload = nil
        close()
    }

    func close() {
        acknowledgement?()
        acknowledgement = nil
        phase = .hidden
    }

    private func answer(_ choice: SPUUserUpdateChoice) {
        let reply = choiceReply
        choiceReply = nil
        if choice != .install { phase = .hidden }
        reply?(choice)
    }

    /// «Снова показывать пропущенные версии».
    func resetSkipped() {
        for key in ["SUSkippedMinorVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion", "SUSkippedVersion"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        refreshSkipped()
    }

    func refreshSkipped() {
        let d = UserDefaults.standard
        hasSkippedVersion = ["SUSkippedMinorVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion", "SUSkippedVersion"]
            .contains { d.object(forKey: $0) != nil }
    }

    /// Через пару секунд прячет сообщения, которые не требуют ответа.
    func autoHide(after seconds: Double, for key: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if phase.key == key { close() }
        }
    }
}

/// Мост между Sparkle и нашей карточкой. Sparkle вызывает методы на главном потоке.
final class ShuttleUserDriver: NSObject, SPUUserDriver {
    private weak var model: UpdateModel?

    init(model: UpdateModel) { self.model = model }

    private func ui(_ work: @MainActor (UpdateModel) -> Void) {
        guard let model else { return }
        MainActor.assumeIsolated { work(model) }
    }

    func show(_ request: SPUUpdatePermissionRequest,
                                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        ui { m in
            m.userInitiated = true
            m.phase = .checking
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let info = UpdateInfo(version: appcastItem.displayVersionString,
                              size: appcastItem.contentLength,
                              notes: Self.notes(from: appcastItem.itemDescription))
        ui { m in
            m.pending = info
            m.choiceReply = reply
            m.lastResult = L("Доступна версия %@", info.version)
            m.lastResultIsError = false
            // Уже скачано в фоне — сразу предлагаем установить.
            m.phase = state.stage == .notDownloaded ? .found(info) : .ready(info)
            if UpdateModel.autoAccept {
                NSLog("Shuttle test: найдено обновление \(info.version), ставим")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { m.install() }
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        ui { m in
            m.lastResult = L("У вас последняя версия — %@", m.currentVersion)
            m.lastResultIsError = false
            guard m.userInitiated else { acknowledgement(); return }
            m.userInitiated = false
            m.acknowledgement = acknowledgement
            m.phase = .upToDate
            m.autoHide(after: 2.5, for: "upToDate")
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if UpdateModel.autoAccept { NSLog("Shuttle test: ошибка обновления: \(error.localizedDescription)") }
        ui { m in
            if m.userInitiated {
                m.lastResult = error.localizedDescription
                m.lastResultIsError = true
            }
            // Фоновые проверки не беспокоят: например, без интернета.
            guard m.userInitiated || m.phase != .hidden else { acknowledgement(); return }
            m.userInitiated = false
            m.acknowledgement = acknowledgement
            m.phase = .failed(error.localizedDescription)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        ui { m in
            m.cancelDownload = cancellation
            m.phase = .downloading(received: 0, total: m.pending?.size ?? 0)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        ui { m in m.phase = .downloading(received: 0, total: expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        ui { m in
            if case .downloading(let r, let t) = m.phase { m.phase = .downloading(received: r + length, total: t) }
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        ui { m in
            m.cancelDownload = nil
            m.phase = .extracting(0)
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        ui { m in m.phase = .extracting(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ui { m in
            m.choiceReply = reply
            if let info = m.pending { m.phase = .ready(info) } else { reply(.install) }
            if UpdateModel.autoAccept {
                NSLog("Shuttle test: скачано, перезапускаем")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { m.install() }
            }
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        ui { m in m.phase = .installing }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        ui { m in
            m.acknowledgement = acknowledgement
            m.phase = .installed(m.pending?.version ?? m.currentVersion)
            m.autoHide(after: 3, for: "installed")
        }
    }

    func showUpdateInFocus() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissUpdateInstallation() {
        ui { m in
            m.choiceReply = nil
            m.cancelDownload = nil
            m.userInitiated = false
            if case .installed = m.phase { return }
            if m.phase.key != "upToDate" && m.phase.key != "failed" { m.phase = .hidden }
        }
    }

    /// Пункты списка изменений из описания версии в appcast (<li>…</li> или строки «- …»).
    static func notes(from html: String?) -> [String] {
        guard let html, !html.isEmpty else { return [] }
        let li = html.components(separatedBy: "<li>").dropFirst().compactMap {
            $0.components(separatedBy: "</li>").first
        }
        let raw = li.isEmpty
            ? html.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("-") || $0.hasPrefix("•") }
                .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
            : li
        return raw.map {
            $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
              .replacingOccurrences(of: "&amp;", with: "&")
              .replacingOccurrences(of: "&lt;", with: "<")
              .replacingOccurrences(of: "&gt;", with: ">")
              .replacingOccurrences(of: "&quot;", with: "\"")
              .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }
}

/// Отладка: подмена адреса списка версий (--update-feed <url>).
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    static var testFeed: String? {
        #if DEBUG
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--update-feed"), i + 1 < a.count { return a[i + 1] }
        #endif
        return nil
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.testFeed }
}
