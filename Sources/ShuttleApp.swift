import SwiftUI

@main
struct ShuttleApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updates = UpdateModel(start: !AppFolders.testing)
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("theme") private var theme: ThemeMode = .system

    init() {
        #if DEBUG
        SelfTest.runIfRequested()
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
        #endif
        if !AppFolders.testing { MenuBarMode.install() }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ThemedRoot(theme: theme) {
                ContentView()
                    .overlay { UpdateOverlay() }
            }
            .environmentObject(state)
            .environmentObject(updates)
            .frame(minWidth: 860, minHeight: 580)
            // The language changed — rebuild the interface.
            .id(settings.language)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 720)
        .commands {
            ShuttleCommands(state: state, theme: $theme)
            CommandGroup(after: .appInfo) {
                Button(L("Проверить обновления…")) { updates.checkNow() }
            }
        }

        Settings {
            ThemedRoot(theme: theme) { SettingsView() }
                .environmentObject(updates)
                .id(settings.language)
        }

        // SwiftUI writes isInserted on every rebuild; writing the same value
        // sends objectWillChange and loops the update — write only real changes.
        // In menu bar mode the icon is always needed — otherwise there's no way to reach Shuttle.
        MenuBarExtra(isInserted: Binding(get: { settings.menuBarIcon || settings.menuBarMode },
                                         set: { if !settings.menuBarMode, settings.menuBarIcon != $0 { settings.menuBarIcon = $0 } })) {
            MenuBarView().environmentObject(state)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

/// Provides the palette for the current (or chosen) theme.
///
/// In Auto mode we read the system theme ourselves and set it on the window explicitly:
/// if we leave it to the system (`preferredColorScheme(nil)`), the window recolors
/// instantly while our colors catch up with an animation — it looks jerky.
struct ThemedRoot<Content: View>: View {
    let theme: ThemeMode
    @ViewBuilder var content: Content
    @StateObject private var system = SystemAppearance()

    var body: some View {
        let scheme = theme.scheme ?? (system.isDark ? .dark : .light)
        content
            .environment(\.palette, Palette.of(scheme))
            // A smooth transition: background, pane and text colors blend,
            // instead of switching abruptly.
            .animation(.easeInOut(duration: 0.4), value: scheme)
            .preferredColorScheme(scheme)
            .tint(Palette.of(scheme).accent)
    }
}

/// The macOS theme, regardless of the theme set on our window.
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

/// Menu bar mode: when the last window closes, Shuttle leaves the Dock,
/// and comes back when the window is opened again.
@MainActor
enum MenuBarMode {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard AppSettings.shared.menuBarMode, let w = n.object as? NSWindow, w.canBecomeMain else { return }
                let others = NSApp.windows.filter { $0 !== w && $0.canBecomeMain && $0.isVisible }
                if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            }
        })
    }

    /// Show the Shuttle window (from the menu): bring back the Dock icon and the window to the front.
    static func showWindow(open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) } else { open() }
    }
}
