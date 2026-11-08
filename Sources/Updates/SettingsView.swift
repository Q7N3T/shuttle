import SwiftUI

/// Settings (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var updates: UpdateModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.palette) private var p
    @AppStorage("theme") private var theme: ThemeMode = .system
    @State private var wifiAddress = ""
    @State private var wifiResult: String?
    @State private var tab: Int
    @Environment(\.isSnapshot) private var snap

    init(startTab: Int = 0) { _tab = State(initialValue: startTab) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DroidMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuttle").font(AppFont.display(15, .bold))
                    Text(L("Версия %@", updates.currentVersion)).font(AppFont.body(12)).foregroundStyle(p.muted)
                }
                Spacer()
            }
            // Tabs on their own row: four of them don't fit on one line with the logo.
            HStack(spacing: 6) {
                tabChip(0, L("Основные"), "gearshape")
                tabChip(1, L("Устройства"), "cable.connector")
                tabChip(2, L("Обновления"), "arrow.triangle.2.circlepath")
                tabChip(3, L("Значки"), "rosette")
            }
            .fixedSize()
            UpdateCheckRow()
            // The tab scrolls inside its own frame: the settings window keeps one height
            // and fits even on a 13-inch screen.
            if snap {
                // A snapshot doesn't draw ScrollView contents — show the whole tab.
                tabContent
            } else {
                ScrollView { tabContent.padding(.bottom, 4) }
                    .scrollIndicators(.automatic)
                    .frame(height: 430)
            }
        }
        .padding(22)
        .frame(width: 560)
        .animation(.easeOut(duration: 0.18), value: tab)
        .background(p.bg)
        .foregroundStyle(p.text)
        .tint(p.accent)
        .onAppear { updates.refreshSkipped() }
    }

    private var tabContent: some View {
        Group {
            switch tab {
            case 1: devices
            case 2: updatesSection
            case 3: AchievementsView()
            default: general
            }
        }
        .transition(.opacity.combined(with: .offset(y: 4)))
        .id(tab)
    }

    private func tabChip(_ i: Int, _ title: String, _ icon: String) -> some View {
        Chip(title: title, icon: icon, isOn: tab == i) { tab = i }
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L("Фото и видео")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Папка для фото с устройств")).font(AppFont.body(13))
                        Text(settings.photosFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(AppFont.body(11)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Chip(title: L("Изменить…")) { choosePhotosFolder() }
                }
                SettingToggle(title: L("HEIC → JPG при скачивании"),
                              hint: L("Фото с iPhone-подобных камер сразу в привычном формате."),
                              isOn: $settings.heicToJPEG)
                SettingToggle(title: L("Превью фото"),
                              hint: L("Миниатюры в списке и сетке. Небольшие файлы скачиваются в кэш."),
                              isOn: $settings.thumbnails)
            }
            section(L("Передачи")) {
                SettingToggle(title: L("Уведомлять, когда передача закончилась"),
                              hint: L("Только если Shuttle в фоне."), isOn: $settings.notifications)
                SettingToggle(title: L("Иконка в строке меню"),
                              hint: L("Устройство, свободное место и быстрые действия."), isOn: $settings.menuBarIcon)
                SettingToggle(title: L("Работать из строки меню"),
                              hint: L("Окно можно закрыть: Shuttle уйдёт из Dock в строку меню, передачи и автоимпорт продолжатся."),
                              isOn: $settings.menuBarMode)
                SettingToggle(title: L("Забирать новые фото сами"),
                              hint: L("При подключении телефона новые фото и видео с камеры сразу скачиваются на Mac."),
                              isOn: $settings.autoImport)
                SettingToggle(title: L("Маскот комментирует"),
                              hint: L("Шаттл в шапке шутит о подключениях и передачах. По клику говорит всегда."),
                              isOn: $settings.mascotTalks)
            }
            section(L("Оформление")) {
                HStack(spacing: 6) {
                    ForEach(ThemeMode.allCases) { m in
                        Chip(title: m.title, icon: m.icon, isOn: theme == m) { theme = m }
                    }
                }
                HStack(spacing: 6) {
                    Text(L("Язык")).font(AppFont.body(13))
                    Spacer()
                    ForEach(AppLanguage.allCases) { l in
                        Chip(title: l.title, isOn: settings.language == l) { settings.language = l }
                    }
                }
            }
        }
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L("Android по ADB")) {
                SettingToggle(title: L("Подключать телефон по ADB"),
                              hint: L("Быстрее MTP, работает по Wi‑Fi, ставит APK и снимает экран. На телефоне нужна «Отладка по USB»."),
                              isOn: $settings.adbEnabled)
                if let exe = ADBDriver.executable {
                    Label(L("adb найден: %@", exe.replacingOccurrences(of: NSHomeDirectory(), with: "~")),
                          systemImage: "checkmark.circle").font(AppFont.body(11)).foregroundStyle(p.ok)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("adb не найден"), systemImage: "exclamationmark.triangle")
                            .font(AppFont.body(11)).foregroundStyle(p.accent)
                        Text(L("Установите Android platform-tools: brew install --cask android-platform-tools"))
                            .font(AppFont.body(11)).foregroundStyle(p.muted).textSelection(.enabled)
                    }
                }
                if settings.adbEnabled, ADBDriver.isAvailable {
                    HStack(spacing: 8) {
                        TextField(L("IP телефона, например 192.168.1.20:5555"), text: $wifiAddress)
                            .textFieldStyle(.roundedBorder)
                        Chip(title: L("По Wi‑Fi"), icon: "wifi") { connectWiFi() }
                            .disabled(wifiAddress.isEmpty)
                    }
                    if let wifiResult { Text(wifiResult).font(AppFont.body(11)).foregroundStyle(p.muted) }
                }
            }
            section("Nintendo Switch") {
                Text(L("Нужна Switch с Atmosphère и DBI. Запустите DBI → «Run MTP responder» и подключите кабель."))
                    .font(AppFont.body(12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Chip(title: L("Папка сейвов"), icon: "tray.full") {
                        NSWorkspace.shared.open(AppFolders.documents(L("Сейвы Switch")))
                    }
                    Chip(title: L("Резервные копии"), icon: "externaldrive") {
                        NSWorkspace.shared.open(AppFolders.documents(L("Резервные копии Switch")))
                    }
                }
            }
            section(L("Кэш")) {
                HStack {
                    Text(L("Превью и временные файлы")).font(AppFont.body(13))
                    Spacer()
                    Chip(title: L("Очистить")) {
                        PreviewCache.clear()
                        try? FileManager.default.removeItem(at: AppFolders.caches.appendingPathComponent("Thumbs"))
                    }
                }
            }
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        section(L("Обновления")) {
            SettingToggle(title: L("Проверять обновления автоматически"),
                          hint: L("Раз в день. Новую версию покажем в окне Shuttle."),
                          isOn: $updates.automaticallyChecks)
            SettingToggle(title: L("Скачивать и устанавливать сами"),
                          hint: L("Обновление поставится при следующем запуске."),
                          isOn: $updates.automaticallyInstalls)
                .disabled(!updates.automaticallyChecks)
                .opacity(updates.automaticallyChecks ? 1 : 0.5)
            HStack(spacing: 8) {
                Chip(title: L("Проверить сейчас"), icon: "arrow.triangle.2.circlepath") { updates.checkNow() }
                if updates.hasSkippedVersion {
                    Chip(title: L("Снова показывать пропущенные"), icon: "arrow.uturn.backward") {
                        withAnimation(.easeOut(duration: 0.2)) { updates.resetSkipped() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            Link(destination: URL(string: "https://github.com/Q7N3T/shuttle/releases")!) {
                Label(L("История версий и старые сборки"), systemImage: "clock.arrow.circlepath")
                    .font(AppFont.body(12))
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppFont.display(12)).foregroundStyle(p.muted)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
        }
    }

    private func choosePhotosFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.photosFolder
        if panel.runModal() == .OK, let u = panel.url { settings.photosFolder = u }
    }

    private func connectWiFi() {
        let addr = wifiAddress
        Task.detached {
            let r = (try? ADBDriver.connectWiFi(addr)) ?? L("Не удалось подключиться")
            await MainActor.run { wifiResult = r }
        }
    }
}

/// A row with a pill toggle and a hint.
struct SettingToggle: View {
    @Environment(\.palette) private var p
    let title: String
    var hint: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isOn.toggle() } } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.body(13))
                    if let hint { Text(hint).font(AppFont.body(11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? p.accent : p.line).frame(width: 36, height: 20)
                    Circle().fill(isOn ? p.ink : p.muted).frame(width: 14, height: 14).padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Checking for updates right in Settings: a button and the result, visible from any tab.
struct UpdateCheckRow: View {
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.body(13, .medium))
                    .foregroundStyle(updates.lastResultIsError && !busy ? p.danger : p.text)
                if let sub = subtitle {
                    Text(sub).font(AppFont.body(11)).foregroundStyle(p.muted)
                }
            }
            .animation(.easeOut(duration: 0.2), value: title)
            Spacer()
            switch updates.phase {
            case .found, .ready:
                AccentButton(title: L("Установить обновление")) { updates.install() }
            default:
                AccentButton(title: busy ? L("Проверяем…") : L("Проверить обновления")) { updates.checkNow() }
                    .disabled(busy)
                    .opacity(busy ? 0.6 : 1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
    }

    private var busy: Bool {
        switch updates.phase {
        case .checking, .downloading, .extracting, .installing: true
        default: false
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch updates.phase {
        case .checking, .downloading, .extracting, .installing:
            ProgressView().controlSize(.small)
        case .found, .ready:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(p.accent)
        default:
            if updates.lastResultIsError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 16)).foregroundStyle(p.danger)
            } else if updates.lastResult != nil {
                DrawnCheck(size: 18, color: p.ok)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 16)).foregroundStyle(p.muted)
            }
        }
    }

    private var title: String {
        switch updates.phase {
        case .checking: return L("Проверяем обновления…")
        case .found(let i), .ready(let i): return L("Доступна версия %@", i.version)
        case .downloading, .extracting: return L("Скачиваем обновление")
        case .installing: return L("Устанавливаем и перезапускаем…")
        default: return updates.lastResult ?? L("Shuttle %@", updates.currentVersion)
        }
    }

    private var subtitle: String? {
        if case .downloading(let r, let t) = updates.phase, t > 0 {
            return L("%@ из %@", formatBytes(r), formatBytes(t))
        }
        if busy { return nil }
        guard let d = updates.lastCheck else { return L("Ещё не проверяли") }
        // Date and time in the interface language, not the system one: no "2:21 PM" in the middle of Russian text.
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.english ? "en_US" : "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        return L("Последняя проверка: %@", f.string(from: d))
    }
}
