import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let focusSearch = Notification.Name("ShuttleFocusSearch")
}

/// The macOS menu bar: File, Edit, View, Go, Device, Help.
/// Split into small blocks: one big menu description overflows the SwiftUI stack.
/// Commands apply to the pane clicked last (Mac or device).
struct ShuttleCommands: Commands {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode

    var body: some Commands {
        FileCommands(state: state, theme: $theme)
        EditCommands(state: state, theme: $theme)
        ViewCommands(state: state, theme: $theme)
        GoCommands(state: state, theme: $theme)
        DeviceCommands(state: state, theme: $theme)
        HelpCommands(state: state, theme: $theme)
    }
}

struct FileCommands: Commands, MenuPickers {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode
    @AppStorage("showMacPane") var showMac = true

    var connected: Bool { state.device != nil }
    var onDevice: Bool { state.activeSide == .device }
    var phone: Bool { state.device?.kind == .phone }
    var console: Bool { state.device?.kind == .console }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("Новая папка на устройстве")) { state.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!connected)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(L("Скачать на Mac")) { state.downloadSelected() }
                .keyboardShortcut("d")
                .disabled(state.androidSelection.isEmpty)
            Button(L("Отправить на устройство")) { state.uploadSelected() }
                .keyboardShortcut("u")
                .disabled(!connected || state.macSelection.isEmpty)
            Button(L("Отправить файлы…")) { pickAndUpload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!connected)
            Divider()
            Button(L("Выбрать папку на Mac…")) { state.chooseMacFolder() }
                .keyboardShortcut("o")
            Button(L("Показать в Finder")) {
                let urls = state.selectedLocalItems.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [state.macURL] : urls)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button(L("Обновить")) { state.refreshAll() }
                .keyboardShortcut("r")
        }
    }
}

struct EditCommands: Commands, MenuPickers {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode
    @AppStorage("showMacPane") var showMac = true

    var connected: Bool { state.device != nil }
    var onDevice: Bool { state.activeSide == .device }
    var phone: Bool { state.device?.kind == .phone }
    var console: Bool { state.device?.kind == .console }

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button(L("Выделить всё")) { state.selectAll() }
                .keyboardShortcut("a")
            Divider()
            Button(L("Переименовать")) { state.renameSelected() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!state.hasSelection)
            Button(L("Переименовать по шаблону…")) { state.beginBatchRename() }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(!state.hasSelection)
            Button(onDevice ? L("Удалить с устройства…") : L("Переместить в Корзину")) { state.deleteSelected() }
                .keyboardShortcut(.delete)
                .disabled(!state.hasSelection)
            Divider()
            Button(L("Найти")) { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("f")
                .disabled(!connected)
            Button(L("Найти дубли на Mac…")) { state.findDuplicates() }
                .disabled(!connected)
        }
    }
}

struct ViewCommands: Commands, MenuPickers {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode
    @AppStorage("showMacPane") var showMac = true

    var connected: Bool { state.device != nil }
    var onDevice: Bool { state.activeSide == .device }
    var phone: Bool { state.device?.kind == .phone }
    var console: Bool { state.device?.kind == .console }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(L("Быстрый просмотр")) { state.quickLook() }
                .keyboardShortcut("y")
                .disabled(!state.hasSelection)
            Button(state.viewMode == .grid ? L("Списком") : L("Сеткой с превью")) {
                state.viewMode = state.viewMode == .grid ? .list : .grid
            }
            .keyboardShortcut("g", modifiers: [.command, .control])
            Divider()
            Picker(L("Тема"), selection: $theme) {
                ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle(L("Панель Mac"), isOn: $showMac)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Toggle(L("Служебные файлы"), isOn: $state.showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Picker(L("Сортировка"), selection: Binding(
                get: { state.sort.key },
                set: { state.toggleSort($0) })) {
                Text(L("По имени")).tag(SortKey.name)
                Text(L("По дате")).tag(SortKey.date)
                Text(L("По размеру")).tag(SortKey.size)
            }
            Toggle(L("По возрастанию"), isOn: Binding(
                get: { state.sort.ascending },
                set: { state.sort.ascending = $0; state.loadMac() }))
            Divider()
            Button(L("История передач")) { state.showHistory = true }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
        }
    }
}

struct GoCommands: Commands, MenuPickers {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode
    @AppStorage("showMacPane") var showMac = true

    var connected: Bool { state.device != nil }
    var onDevice: Bool { state.activeSide == .device }
    var phone: Bool { state.device?.kind == .phone }
    var console: Bool { state.device?.kind == .console }

    var body: some Commands {
        CommandMenu(L("Переход")) {
            Button(L("Наверх")) { state.goUp() }
                .keyboardShortcut(.upArrow)
            Button(L("Открыть")) { state.openSelected() }
                .keyboardShortcut(.downArrow)
            Divider()
            Button(L("Загрузки на Mac")) {
                state.setMac(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            if let storages = state.device?.storages, !storages.isEmpty {
                Divider()
                ForEach(Array(storages.prefix(9).enumerated()), id: \.element.id) { i, s in
                    Button(s.name) { state.selectStorage(at: i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
            let favs = FavoritesStore.shared.list(state.deviceKey)
            if !favs.isEmpty {
                Divider()
                Menu(L("Избранное")) {
                    ForEach(favs) { f in Button(f.title) { state.openFavorite(f) } }
                }
            }
            if let fav = state.currentFavorite, state.androidPath.count > 1 {
                Button(FavoritesStore.shared.contains(fav, device: state.deviceKey)
                       ? L("Убрать папку из избранного") : L("Добавить папку в избранное")) { state.toggleFavorite(fav) }
                    .keyboardShortcut("d", modifiers: [.command, .option])
            }
        }
    }
}

struct DeviceCommands: Commands, MenuPickers {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode
    @AppStorage("showMacPane") var showMac = true

    var connected: Bool { state.device != nil }
    var onDevice: Bool { state.activeSide == .device }
    var phone: Bool { state.device?.kind == .phone }
    var console: Bool { state.device?.kind == .console }

    var body: some Commands {
        CommandMenu(L("Устройство")) {
            if phone {
                Button(L("Скачать новое с камеры (%d)", state.newPhotos.count)) { state.importNewPhotos() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(state.newPhotos.isEmpty)
                Button(L("Синхронизация папок…")) { state.showSync = true }
                Button(L("Добавить текущую папку в синхронизацию…")) { state.addSyncRuleForCurrentFolder() }
                if state.device?.transport == .adb {
                    Divider()
                    Button(L("Снимок экрана телефона")) { state.takeScreenshot() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Button(L("Установить APK…")) { pickAPK() }
                }
            }
            if console {
                Button(L("Установить игру…")) { pickGames() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button(L("Установить homebrew из архива…")) { pickHomebrew() }
                Divider()
                Button(L("Сохранить все сейвы на Mac")) { state.backupSaves() }
                Button(L("Обновить Atmosphère…")) { state.checkAtmosphere() }
            }
            if !connected {
                Text(L("Устройство не подключено"))
            }
        }
    }
}

struct HelpCommands: Commands, MenuPickers {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode
    @AppStorage("showMacPane") var showMac = true

    var connected: Bool { state.device != nil }
    var onDevice: Bool { state.activeSide == .device }
    var phone: Bool { state.device?.kind == .phone }
    var console: Bool { state.device?.kind == .console }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Link(L("Справка Shuttle"), destination: URL(string: "https://github.com/Q7N3T/shuttle#readme")!)
            Link(L("Как подключить Switch"), destination: URL(string: L("https://github.com/Q7N3T/shuttle#подключение"))!)
            Link(L("История версий"), destination: URL(string: "https://github.com/Q7N3T/shuttle/blob/main/CHANGELOG.md")!)
        }
    }
}

/// Picking files for menu commands.
protocol MenuPickers {
    var state: AppState { get }
}

@MainActor
extension MenuPickers {

    func pick(_ types: [UTType], multiple: Bool = true, prompt: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = types.isEmpty
        panel.canChooseFiles = true
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : []
    }

    func pickAndUpload() {
        let urls = pick([], prompt: L("Отправить"))
        if !urls.isEmpty { state.handleDrop(urls) }
    }

    func pickGames() {
        let types = GameFiles.installable.compactMap { UTType(filenameExtension: $0) }
        let urls = pick(types, prompt: L("Установить"))
        if !urls.isEmpty { state.pendingInstall = PendingInstall(files: urls) }
    }

    func pickHomebrew() {
        let urls = pick([.zip], multiple: false, prompt: L("Установить"))
        if let u = urls.first { state.pendingHomebrew = u }
    }

    func pickAPK() {
        let types = [UTType(filenameExtension: "apk") ?? .data]
        let urls = pick(types, prompt: L("Установить"))
        if !urls.isEmpty { state.pendingAPK = urls }
    }

}
