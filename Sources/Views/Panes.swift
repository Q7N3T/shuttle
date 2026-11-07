import SwiftUI
import UniformTypeIdentifiers

// MARK: - Общие части панелей

struct PaneShell<Header: View, Content: View>: View {
    @Environment(\.palette) private var p
    var isTargeted: Bool
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .frame(height: 40)
            Rectangle().fill(p.line).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(isTargeted ? p.hover : p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isTargeted ? p.accent : p.line,
                                                            lineWidth: isTargeted ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

struct FileRow: View {
    @Environment(\.palette) private var p
    let name: String
    let size: UInt64
    let isFolder: Bool
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon(name: name, isFolder: isFolder))
                .font(.system(size: 14))
                .foregroundStyle(isFolder ? p.accent : p.muted)
                .frame(width: 18)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if !isFolder {
                Text(formatBytes(size)).font(AppFont.body(11)).foregroundStyle(p.muted)
            } else {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.muted.opacity(0.7))
            }
        }
        .font(AppFont.body(13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? p.accent.opacity(0.18) : (hover ? p.hover : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? p.accent.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

func fileIcon(name: String, isFolder: Bool) -> String {
    if isFolder { return "folder.fill" }
    guard let t = UTType(filenameExtension: (name as NSString).pathExtension.lowercased()) else { return "doc" }
    if t.conforms(to: .image) { return "photo" }
    if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
    if t.conforms(to: .audio) { return "music.note" }
    if t.conforms(to: .archive) { return "doc.zipper" }
    if t.conforms(to: .pdf) || t.conforms(to: .text) { return "doc.text" }
    if t.identifier == "com.android.package-archive" { return "shippingbox" }
    return "doc"
}

/// Пустое состояние или подсказка.
struct Hint: View {
    @Environment(\.palette) private var p
    let icon: String
    let title: String
    var lines: [String] = []

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(p.accent)
            Text(title).font(AppFont.display(13))
            ForEach(lines, id: \.self) { Text($0).font(AppFont.body(12)).foregroundStyle(p.muted) }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Обработка клика: обычный — выбрать, ⌘ — добавить к выбору.
func toggleSelection<T: Hashable>(_ set: inout Set<T>, _ id: T) {
    if NSEvent.modifierFlags.contains(.command) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    } else {
        set = [id]
    }
}

// MARK: - Mac

struct MacPane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.isSnapshot) private var snap
    @State private var targeted = false

    var body: some View {
        PaneShell(isTargeted: targeted) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(p.muted)
                Text("Mac").font(AppFont.display(12))
                IconButton(systemName: "chevron.left", help: "Наверх") { state.macUp() }
                if snap {
                    Text(displayPath).font(AppFont.body(12)).foregroundStyle(p.muted)
                } else {
                Menu {
                    ForEach(favorites, id: \.0) { f in
                        Button(f.0) { state.setMac(f.1) }
                    }
                    Divider()
                    Button("Другая папка…") { state.chooseMacFolder() }
                } label: {
                    Text(displayPath).font(AppFont.body(12)).foregroundStyle(p.muted)
                        .lineLimit(1).truncationMode(.head)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: "Обновить") { state.loadMac() }
                IconButton(systemName: "arrow.up.forward.app", help: "Открыть в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.macURL])
                }
            }
        } content: {
            if state.macItems.isEmpty {
                Hint(icon: "tray", title: "Папка пуста", lines: ["Перетащите сюда файлы с телефона"])
            } else {
                Scrollable {
                    LazyVStack(spacing: 2) {
                        ForEach(state.macItems) { item in
                            FileRow(name: item.name, size: item.size, isFolder: item.isFolder,
                                    selected: state.macSelection.contains(item.url))
                                .onTapGesture(count: 2) { state.openMac(item) }
                                .onTapGesture { toggleSelection(&state.macSelection, item.url) }
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
            // Принимаем только то, что тащат из панели Android.
            guard !state.draggingRemote.isEmpty else { return false }
            let items = state.draggingRemote
            state.draggingRemote = []
            state.download(items)
            return true
        }
    }

    @ViewBuilder
    private func menu(for item: LocalItem) -> some View {
        let items = state.selectedLocal(orItem: item)
        Button("Открыть") { state.openMac(item) }
        Button(items.count > 1 ? "Отправить на Android (\(items.count))" : "Отправить на Android") {
            state.upload(items.map(\.url))
        }
        .disabled(state.connection.info == nil)
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
    }

    private var displayPath: String {
        state.macURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var favorites: [(String, URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            ("Загрузки", fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]),
            ("Рабочий стол", fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]),
            ("Документы", fm.urls(for: .documentDirectory, in: .userDomainMask)[0]),
            ("Изображения", fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]),
            ("Домой", home),
        ]
    }
}

// MARK: - Android

struct AndroidPane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @State private var targeted = false
    @State private var newFolderName = ""
    @State private var askNewFolder = false
    @State private var renaming: RemoteItem?
    @State private var renameText = ""
    @State private var toDelete: [RemoteItem] = []

    var body: some View {
        PaneShell(isTargeted: targeted) {
            HStack(spacing: 8) {
                DroidMark(size: 16, glow: false)
                Text("Android").font(AppFont.display(12))
                if state.connection.info != nil {
                    IconButton(systemName: "chevron.left", help: "Наверх") { state.androidUp() }
                    breadcrumbs
                    Spacer()
                    if state.androidLoading { ProgressView().controlSize(.small) }
                    IconButton(systemName: "folder.badge.plus", help: "Новая папка") {
                        newFolderName = ""; askNewFolder = true
                    }
                    IconButton(systemName: "arrow.clockwise", help: "Обновить") {
                        Task { await state.loadAndroid() }
                    }
                } else {
                    Spacer()
                }
            }
        } content: {
            content
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard state.connection.info != nil else { return false }
            loadURLs(providers) { state.upload($0) }
            return true
        }
        .alert("Новая папка", isPresented: $askNewFolder) {
            TextField("Название", text: $newFolderName)
            Button("Создать") { state.createAndroidFolder(newFolderName.trimmingCharacters(in: .whitespaces)) }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $renameText)
            Button("Готово") { if let r = renaming { state.renameAndroid(r, to: renameText) } }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !toDelete.isEmpty },
                                                              set: { if !$0 { toDelete = [] } })) {
            Button("Удалить", role: .destructive) { state.deleteAndroid(toDelete) }
        } message: {
            Text("Файлы удалятся с телефона без корзины.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.connection {
        case .searching:
            Hint(icon: "cable.connector", title: "Подключите телефон",
                 lines: ["Кабель USB → уведомление на телефоне → «Передача файлов»"])
        case .busy:
            Hint(icon: "exclamationmark.triangle", title: "Телефон занят другой программой",
                 lines: ["Закройте «Захват изображений», «Фото»", "и Android File Transfer, если они открыты"])
        case .locked:
            Hint(icon: "lock", title: "Разблокируйте телефон",
                 lines: ["и выберите режим USB «Передача файлов»"])
        case .connected:
            if state.androidItems.isEmpty && !state.androidLoading {
                Hint(icon: "tray", title: "Здесь пусто", lines: ["Перетащите файлы из Finder или левой панели"])
            } else {
                Scrollable {
                    LazyVStack(spacing: 2) {
                        ForEach(state.androidItems) { item in
                            FileRow(name: item.name, size: item.size, isFolder: item.isFolder,
                                    selected: state.androidSelection.contains(item.id))
                                .onTapGesture(count: 2) { state.openAndroid(item) }
                                .onTapGesture { toggleSelection(&state.androidSelection, item.id) }
                                .onDrag {
                                    state.draggingRemote = state.selectedRemote(orItem: item)
                                    return state.itemProvider(for: item, state: state)
                                }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: RemoteItem) -> some View {
        let items = state.selectedRemote(orItem: item)
        if item.isFolder { Button("Открыть") { state.openAndroid(item) } }
        Button(items.count > 1 ? "Скачать на Mac (\(items.count))" : "Скачать на Mac") { state.download(items) }
        Button("Переименовать") { renameText = item.name; renaming = item }
            .disabled(items.count > 1)
        Divider()
        Button("Удалить…", role: .destructive) { toDelete = items }
    }

    private var deleteTitle: String {
        toDelete.count == 1 ? "Удалить «\(toDelete[0].name)»?" : "Удалить \(toDelete.count) объекта?"
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(state.androidPath.enumerated()), id: \.offset) { i, c in
                if i > 0 { Text("/").foregroundStyle(p.muted.opacity(0.6)) }
                Button(c.name) { state.goToCrumb(i) }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == state.androidPath.count - 1 ? p.text : p.muted)
            }
        }
        .font(AppFont.body(12))
        .lineLimit(1)
        .truncationMode(.head)
    }
}

/// Достаёт file URL из перетаскиваемых объектов.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let result = urls
        MainActor.assumeIsolated { completion(result) }
    }
}
