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
                .padding(.horizontal, 10)
                .frame(height: 38)
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

/// Ширины колонок таблицы.
enum Col {
    static let date: CGFloat = 118
    static let size: CGFloat = 70
    static let indent: CGFloat = 14
    /// Уже этого колонка даты прячется.
    static let compactBelow: CGFloat = 440
}

/// Заголовок таблицы с сортировкой по клику.
struct ColumnHeader: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    var compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            cell("Название", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            if !compact { cell("Изменён", .date).frame(width: Col.date, alignment: .leading) }
            cell("Размер", .size).frame(width: Col.size, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 24)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.6)).frame(height: 1) }
    }

    private func cell(_ title: String, _ key: SortKey) -> some View {
        let on = state.sort.key == key
        return Button { state.toggleSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if on {
                    Image(systemName: state.sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(AppFont.body(11, on ? .medium : .regular))
            .foregroundStyle(on ? p.text : p.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Строка таблицы: треугольник, иконка, имя, дата, размер.
struct FileTableRow: View {
    @Environment(\.palette) private var p
    let name: String
    let isFolder: Bool
    let size: UInt64
    let modified: Date
    var depth: Int = 0
    /// nil — строка без раскрытия (панель Mac).
    var expanded: Bool? = nil
    var loading = false
    var selected = false
    var dropTarget = false
    var compact = false
    var onToggle: () -> Void = {}
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * Col.indent, height: 1)
                disclosure
                Image(systemName: fileIcon(name: name, isFolder: isFolder))
                    .font(.system(size: 12))
                    .foregroundStyle(isFolder ? p.accent : p.muted)
                    .frame(width: 16)
                Text(name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(name.hasPrefix(".") ? p.muted : p.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(formatDate(modified)).foregroundStyle(p.muted)
                    .frame(width: Col.date, alignment: .leading)
            }
            Text(isFolder ? "—" : formatBytes(size)).foregroundStyle(p.muted).monospacedDigit()
                .frame(width: Col.size, alignment: .trailing)
        }
        .font(AppFont.body(12))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(dropTarget ? p.accent : (selected ? p.accent.opacity(0.45) : .clear), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var fill: Color {
        if dropTarget { return p.accent.opacity(0.22) }
        if selected { return p.accent.opacity(0.16) }
        return hover ? p.hover : .clear
    }

    @ViewBuilder
    private var disclosure: some View {
        if let expanded, isFolder {
            Button(action: onToggle) {
                Group {
                    if loading {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.12), value: expanded)
                    }
                }
                .foregroundStyle(p.muted)
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }
}

func fileIcon(name: String, isFolder: Bool) -> String {
    if isFolder { return "folder.fill" }
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "nsp", "nsz", "xci", "xcz": return "gamecontroller"
    case "nro", "ovl", "kip": return "app.badge"
    case "bin", "dat": return "cpu"
    case "ini", "json", "toml", "cfg", "log": return "slider.horizontal.3"
    case "apk": return "shippingbox"
    default: break
    }
    guard let t = UTType(filenameExtension: ext) else { return "doc" }
    if t.conforms(to: .image) { return "photo" }
    if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
    if t.conforms(to: .audio) { return "music.note" }
    if t.conforms(to: .archive) { return "doc.zipper" }
    if t.conforms(to: .pdf) || t.conforms(to: .text) { return "doc.text" }
    return "doc"
}

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    return f
}()

func formatDate(_ d: Date) -> String {
    // DBI и часть телефонов дату не отдают (0 → 1970).
    guard d.timeIntervalSince1970 > 315_532_800 else { return "—" }
    let cal = Calendar.current
    if cal.isDateInToday(d) {
        dateFormatter.dateFormat = "'Сегодня,' HH:mm"
    } else if cal.isDate(d, equalTo: .now, toGranularity: .year) {
        dateFormatter.dateFormat = "d MMM, HH:mm"
    } else {
        dateFormatter.dateFormat = "d MMM yyyy"
    }
    return dateFormatter.string(from: d)
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

/// Таблица с заголовком; колонка даты прячется, когда панель узкая.
struct FileTable<Rows: View>: View {
    @Environment(\.isSnapshot) private var snap
    var snapshotWidth: CGFloat = 500
    @ViewBuilder var rows: (_ compact: Bool) -> Rows

    var body: some View {
        if snap {
            table(compact: snapshotWidth < Col.compactBelow)
        } else {
            GeometryReader { g in table(compact: g.size.width < Col.compactBelow) }
        }
    }

    private func table(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ColumnHeader(compact: compact)
            Scrollable {
                LazyVStack(spacing: 1) { rows(compact) }.padding(6)
            }
        }
    }
}

// MARK: - Mac

struct MacPane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.isSnapshot) private var snap
    @State private var targeted = false
    var snapshotWidth: CGFloat = 500

    var body: some View {
        PaneShell(isTargeted: targeted) {
            HStack(spacing: 6) {
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
                Hint(icon: "tray", title: "Папка пуста", lines: ["Перетащите сюда файлы с устройства"])
            } else {
                FileTable(snapshotWidth: snapshotWidth) { compact in
                    ForEach(state.macItems) { item in
                        FileTableRow(name: item.name, isFolder: item.isFolder, size: item.size,
                                     modified: item.modified,
                                     selected: state.macSelection.contains(item.url), compact: compact)
                            .onTapGesture(count: 2) { state.openMac(item) }
                            .onTapGesture { toggleSelection(&state.macSelection, item.url) }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .contextMenu { menu(for: item) }
                    }
                }
            }
        }
        .onDrop(of: [.plainText], isTargeted: $targeted) { _ in
            // Принимаем только то, что тащат из панели устройства.
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
        Button(items.count > 1 ? "Отправить на устройство (\(items.count))" : "Отправить на устройство") {
            state.upload(items.map(\.url))
        }
        .disabled(state.device == nil)
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
    }

    private var displayPath: String {
        state.macURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var favorites: [(String, URL)] {
        let fm = FileManager.default
        return [
            ("Загрузки", fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]),
            ("Рабочий стол", fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]),
            ("Документы", fm.urls(for: .documentDirectory, in: .userDomainMask)[0]),
            ("Изображения", fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]),
            ("Домой", fm.homeDirectoryForCurrentUser),
        ]
    }
}

// MARK: - Устройство

struct DevicePane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @State private var targeted = false
    @State private var newFolderName = ""
    @State private var askNewFolder = false
    @State private var renaming: RemoteItem?
    @State private var renameText = ""
    @State private var toDelete: [RemoteItem] = []
    var snapshotWidth: CGFloat = 500

    var body: some View {
        PaneShell(isTargeted: targeted) {
            HStack(spacing: 6) {
                if state.device?.kind == .console {
                    JoyConMark(size: 16)
                } else {
                    DroidMark(size: 16, glow: false)
                }
                if state.device != nil {
                    IconButton(systemName: "chevron.left", help: "Наверх") { state.androidUp() }
                    breadcrumbs
                    Spacer(minLength: 4)
                    if state.androidLoading { ProgressView().controlSize(.small) }
                    if state.device?.kind == .phone {
                        IconButton(systemName: state.showHidden ? "eye" : "eye.slash",
                                   help: state.showHidden ? "Скрыть служебные" : "Показать служебные") {
                            state.showHidden.toggle()
                        }
                    }
                    IconButton(systemName: "folder.badge.plus", help: "Новая папка") {
                        newFolderName = ""; askNewFolder = true
                    }
                    IconButton(systemName: "arrow.clockwise", help: "Обновить") { state.refreshAndroid() }
                } else {
                    Text("Устройство").font(AppFont.display(12))
                    Spacer()
                }
            }
        } content: {
            content
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard state.device != nil else { return false }
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
            Text("Файлы удалятся с устройства без корзины.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.connection {
        case .searching:
            Hint(icon: "cable.connector", title: "Подключите устройство",
                 lines: ["Android: уведомление USB → «Передача файлов»",
                         "Switch: DBI → «Run MTP responder»"])
        case .busy:
            Hint(icon: "exclamationmark.triangle", title: "Устройство занято другой программой",
                 lines: ["Закройте «Захват изображений», «Фото»", "и Android File Transfer, если они открыты"])
        case .locked:
            Hint(icon: "lock", title: "Разблокируйте телефон",
                 lines: ["и выберите режим USB «Передача файлов»"])
        case .connected:
            let rows = state.androidRows
            if rows.isEmpty && !state.androidLoading {
                Hint(icon: "tray", title: "Здесь пусто", lines: ["Перетащите файлы из Finder или панели Mac"])
            } else {
                FileTable(snapshotWidth: snapshotWidth) { compact in
                    ForEach(rows) { row in
                        DeviceRow(row: row, compact: compact,
                                  onRename: { renameText = row.item.name; renaming = row.item },
                                  onDelete: { toDelete = state.selectedRemote(orItem: row.item) })
                    }
                }
            }
        }
    }

    private var deleteTitle: String {
        toDelete.count == 1 ? "Удалить «\(toDelete[0].name)»?" : "Удалить объектов: \(toDelete.count)?"
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

/// Строка устройства: своё состояние подсветки при перетаскивании на папку.
struct DeviceRow: View {
    @EnvironmentObject private var state: AppState
    let row: RemoteRow
    let compact: Bool
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var dropTarget = false

    var body: some View {
        let item = row.item
        FileTableRow(name: item.name, isFolder: item.isFolder, size: item.size, modified: item.modified,
                     depth: row.depth, expanded: state.isExpanded(item), loading: state.isLoading(item),
                     selected: state.androidSelection.contains(item.id), dropTarget: dropTarget,
                     compact: compact, onToggle: { state.toggleExpand(item) })
            .onTapGesture(count: 2) { item.isFolder ? state.openAndroid(item) : state.download([item]) }
            .onTapGesture { toggleSelection(&state.androidSelection, item.id) }
            .onDrag {
                state.draggingRemote = state.selectedRemote(orItem: item)
                return state.itemProvider(for: item, state: state)
            }
            .modifier(FolderDrop(enabled: item.isFolder, targeted: $dropTarget) { urls in
                state.upload(urls, into: item)
            })
            .contextMenu {
                let items = state.selectedRemote(orItem: item)
                if item.isFolder {
                    Button("Открыть") { state.openAndroid(item) }
                    Button(state.isExpanded(item) ? "Свернуть" : "Развернуть") { state.toggleExpand(item) }
                }
                Button(items.count > 1 ? "Скачать на Mac (\(items.count))" : "Скачать на Mac") {
                    state.download(items)
                }
                Button("Переименовать", action: onRename).disabled(items.count > 1)
                Divider()
                Button("Удалить…", role: .destructive, action: onDelete)
            }
    }
}

/// Бросить файлы прямо на папку в списке.
struct FolderDrop: ViewModifier {
    @Environment(\.isSnapshot) private var snap
    let enabled: Bool
    @Binding var targeted: Bool
    let perform: @MainActor ([URL]) -> Void

    func body(content: Content) -> some View {
        if enabled && !snap {
            content.onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                loadURLs(providers, completion: perform)
                return true
            }
        } else {
            content
        }
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
