import SwiftUI

/// Строка меню macOS: Файл, Правка, Вид, Переход, Справка.
/// Команды относятся к панели, где последний раз кликали (Mac или устройство).
struct ShuttleCommands: Commands {
    @ObservedObject var state: AppState
    @Binding var theme: ThemeMode
    @AppStorage("showMacPane") private var showMac = true

    private var connected: Bool { state.device != nil }
    private var onDevice: Bool { state.activeSide == .device }

    var body: some Commands {
        // MARK: Файл
        CommandGroup(replacing: .newItem) {
            Button("Новая папка на устройстве") { state.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!connected)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Скачать на Mac") { state.downloadSelected() }
                .keyboardShortcut("d")
                .disabled(state.androidSelection.isEmpty)
            Button("Отправить на устройство") { state.uploadSelected() }
                .keyboardShortcut("u")
                .disabled(!connected || state.macSelection.isEmpty)
            Divider()
            Button("Выбрать папку на Mac…") { state.chooseMacFolder() }
                .keyboardShortcut("o")
            Button("Показать в Finder") {
                let urls = state.selectedLocalItems.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [state.macURL] : urls)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Обновить") { state.refreshAll() }
                .keyboardShortcut("r")
        }

        // MARK: Правка
        CommandGroup(replacing: .pasteboard) {
            Button("Выделить всё") { state.selectAll() }
                .keyboardShortcut("a")
            Divider()
            Button("Переименовать") { state.renameSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!onDevice || state.selectedRemoteItems.count != 1)
            Button(onDevice ? "Удалить с устройства…" : "Переместить в Корзину") { state.deleteSelected() }
                .keyboardShortcut(.delete)
                .disabled(!state.hasSelection)
        }

        // MARK: Вид
        CommandGroup(before: .toolbar) {
            Picker("Тема", selection: $theme) {
                ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle("Панель Mac", isOn: $showMac)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Toggle("Служебные файлы", isOn: $state.showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Picker("Сортировка", selection: Binding(
                get: { state.sort.key },
                set: { state.toggleSort($0) })) {
                Text("По имени").tag(SortKey.name)
                Text("По дате").tag(SortKey.date)
                Text("По размеру").tag(SortKey.size)
            }
            Toggle("По возрастанию", isOn: Binding(
                get: { state.sort.ascending },
                set: { state.sort.ascending = $0; state.loadMac() }))
            Divider()
        }

        // MARK: Переход
        CommandMenu("Переход") {
            Button("Наверх") { state.goUp() }
                .keyboardShortcut(.upArrow)
            Button("Открыть") { state.openSelected() }
                .keyboardShortcut(.downArrow)
            Divider()
            Button("Загрузки на Mac") {
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
        }

        // MARK: Справка
        CommandGroup(replacing: .help) {
            Link("Справка Shuttle", destination: URL(string: "https://github.com/Q7N3T/shuttle#readme")!)
            Link("Как подключить Switch", destination: URL(string: "https://github.com/Q7N3T/shuttle#подключение")!)
        }
    }
}
