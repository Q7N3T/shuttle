import SwiftUI

@main
struct ShuttleApp: App {
    @StateObject private var state = AppState()
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
            }
            .environmentObject(state)
            .frame(minWidth: 820, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Вид") {
                Picker("Тема", selection: $theme) {
                    ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

/// Подставляет палитру под текущую (или выбранную) тему.
struct ThemedRoot<Content: View>: View {
    let theme: ThemeMode
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var system

    var body: some View {
        let scheme = theme.scheme ?? system
        content
            .environment(\.palette, Palette.of(scheme))
            .preferredColorScheme(theme.scheme)
            .tint(Palette.of(scheme).accent)
    }
}
