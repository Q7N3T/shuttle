import AppKit

/// "Report a problem": a new GitHub issue with the version, macOS, the device and recent errors
/// already filled in. The person sees the whole text in the browser and can edit it before sending.
@MainActor
enum IssueReport {
    static func url(device: DeviceInfo?, switchWithoutMTP: Bool) -> URL {
        let b = Bundle.main
        let ver = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        let dev: String
        if let d = device { dev = "\(d.name) · \(d.kind == .console ? "Switch" : "Android") · \(d.transport == .adb ? "ADB" : "MTP")" }
        else if switchWithoutMTP { dev = L("Switch подключена, но DBI не в режиме MTP") }
        else { dev = L("не подключено") }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let errors = HistoryStore.shared.entries.filter { !$0.ok }.prefix(5).map {
            "- \(df.string(from: $0.date)) · \($0.device) · \($0.name)" + ($0.note.map { " — \($0)" } ?? "")
        }
        var body = """
        ### \(L("Что случилось"))

        <!-- \(L("Опишите, что делали и что пошло не так. Весь текст ниже можно поправить перед отправкой.")) -->

        ### \(L("Как повторить"))

        1.

        ---
        - Wirrow \(ver) (\(build))
        - macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch)
        - \(L("Устройство")): \(dev)
        - \(L("Питание Mac")): \(PowerSource.shared.onBattery ? L("батарея") : L("зарядка"))
        """
        if !errors.isEmpty { body += "\n\n**\(L("Последние ошибки"))**\n" + errors.joined(separator: "\n") }
        var c = URLComponents(string: "https://github.com/Q7N3T/wirrow/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        return c.url!
    }

    static func open() {
        let s = AppState.current
        NSWorkspace.shared.open(url(device: s?.device, switchWithoutMTP: s?.nintendoWithoutMTP ?? false))
    }
}
