import SwiftUI

@main
struct ShuttleApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updates = UpdateModel()
    @AppStorage("theme") private var theme: ThemeMode = .system

    init() {
        #if DEBUG
        SelfTest.runIfRequested()
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ThemedRoot(theme: theme) {
                ContentView()
                    .overlay { UpdateOverlay() }
            }
            .environmentObject(state)
            .environmentObject(updates)
            .frame(minWidth: 820, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1040, height: 700)
        .commands {
            ShuttleCommands(state: state, theme: $theme)
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { updates.checkNow() }
            }
        }

        Settings {
            ThemedRoot(theme: theme) { SettingsView() }
                .environmentObject(updates)
        }
    }
}

/// Подставляет палитру под текущую (или выбранную) тему.
///
/// В режиме «Авто» тему системы читаем сами и задаём окну явно:
/// если отдать её системе (`preferredColorScheme(nil)`), окно перекрашивается
/// мгновенно, а наши цвета догоняют с анимацией — получается рывок.
struct ThemedRoot<Content: View>: View {
    let theme: ThemeMode
    @ViewBuilder var content: Content
    @StateObject private var system = SystemAppearance()

    var body: some View {
        let scheme = theme.scheme ?? (system.isDark ? .dark : .light)
        content
            .environment(\.palette, Palette.of(scheme))
            // Плавный переход: цвета фона, панелей и текста перетекают,
            // а не переключаются рывком.
            .animation(.easeInOut(duration: 0.4), value: scheme)
            .preferredColorScheme(scheme)
            .tint(Palette.of(scheme).accent)
    }
}

/// Тема macOS, независимо от темы, выставленной нашему окну.
final class SystemAppearance: ObservableObject {
    @Published private(set) var isDark = SystemAppearance.read()
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            let dark = SystemAppearance.read()
            if self?.isDark != dark { self?.isDark = dark }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private static func read() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let v = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return v == "Dark"
    }
}
