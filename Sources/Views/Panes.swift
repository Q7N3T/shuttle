import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pane parts

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

/// Table column widths.
enum Col {
    static let date: CGFloat = 118
    static let size: CGFloat = 70
    static let indent: CGFloat = 14
    /// Narrower than this, the date column hides.
    static let compactBelow: CGFloat = 440
}

/// The table header with click-to-sort.
struct ColumnHeader: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    var compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            cell(L("Название"), .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            if !compact { cell(L("Изменён"), .date).frame(width: Col.date, alignment: .leading) }
            cell(L("Размер"), .size).frame(width: Col.size, alignment: .trailing)
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

/// A table row: disclosure triangle, icon or thumbnail, name, date, size.
struct FileTableRow: View {
    @Environment(\.palette) private var p
    let name: String
    let isFolder: Bool
    let size: UInt64
    let modified: Date
    var depth: Int = 0
    /// nil — a row without disclosure (Mac pane).
    var expanded: Bool? = nil
    var loading = false
    var selected = false
    var dropTarget = false
    var compact = false
    var thumbnail: NSImage? = nil
    /// Show instead of the name (e.g. a game title).
    var title: String? = nil
    /// A small caption right of the name: the path in search, a game ID.
    var subtitle: String? = nil
    var onMac = false
    var onToggle: () -> Void = {}
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * Col.indent, height: 1)
                disclosure
                icon
                Text(title ?? name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(name.hasPrefix(".") ? p.muted : p.text)
                    .help(title != nil ? name : "")
                if let subtitle {
                    Text(subtitle).font(AppFont.body(10)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.head)
                }
                if onMac {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(p.ok.opacity(0.8))
                        .help(L("Уже есть на Mac"))
                }
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

    @ViewBuilder
    private var icon: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                .transition(.opacity)
        } else {
            Image(systemName: fileIcon(name: name, isFolder: isFolder))
                .font(.system(size: 12))
                .foregroundStyle(isFolder ? p.accent : p.muted)
                .frame(width: 18)
        }
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
    case "bin", "dat", "nca": return "cpu"
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
    return f
}()

func formatDate(_ d: Date) -> String {
    // DBI and some phones don't report a date (0 → 1970).
    guard d.timeIntervalSince1970 > 315_532_800 else { return "—" }
    dateFormatter.locale = Locale(identifier: L10n.english ? "en_US" : "ru_RU")
    let cal = Calendar.current
    if cal.isDateInToday(d) {
        dateFormatter.dateFormat = "'\(L("Сегодня")),' HH:mm"
    } else if cal.isDate(d, equalTo: .now, toGranularity: .year) {
        dateFormatter.dateFormat = "d MMM, HH:mm"
    } else {
        dateFormatter.dateFormat = "d MMM yyyy"
    }
    return dateFormatter.string(from: d)
}

/// An empty state or a hint.
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

/// Click handling: plain — select, ⌘ — add to the selection.
func toggleSelection<T: Hashable>(_ set: inout Set<T>, _ id: T) {
    if NSEvent.modifierFlags.contains(.command) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    } else {
        set = [id]
    }
}

/// A table with a header; the date column hides when the pane is narrow.
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
    @FocusState private var focused: Bool
    var snapshotWidth: CGFloat = 500

    var body: some View {
        PaneShell(isTargeted: targeted) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").foregroundStyle(p.muted)
                Text("Mac").font(AppFont.display(12))
                IconButton(systemName: "chevron.left", help: L("Наверх")) { state.macUp() }
                if snap {
                    Text(displayPath).font(AppFont.body(12)).foregroundStyle(p.muted)
                } else {
                    Menu {
                        ForEach(favorites, id: \.0) { f in
                            Button(f.0) { state.setMac(f.1) }
                        }
                        Divider()
                        Button(L("Другая папка…")) { state.chooseMacFolder() }
                    } label: {
                        Text(displayPath).font(AppFont.body(12)).foregroundStyle(p.muted)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: L("Обновить")) { state.loadMac() }
                IconButton(systemName: "arrow.up.forward.app", help: L("Открыть в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([state.macURL])
                }
            }
        } content: {
            if state.macItems.isEmpty {
                Hint(icon: "tray", title: L("Папка пуста"), lines: [L("Перетащите сюда файлы с устройства")])
            } else {
                FileTable(snapshotWidth: snapshotWidth) { compact in
                    ForEach(state.macItems) { item in
                        FileTableRow(name: item.name, isFolder: item.isFolder, size: item.size,
                                     modified: item.modified,
                                     selected: state.macSelection.contains(item.url), compact: compact)
                            .onTapGesture(count: 2) { state.openMac(item) }
                            .onTapGesture {
                                state.activeSide = .mac
                                focused = true
                                toggleSelection(&state.macSelection, item.url)
                            }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .contextMenu { menu(for: item) }
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { state.activeSide = .mac; state.quickLook(); return .handled }
        .modifier(DropTarget(types: [.plainText], targeted: $targeted) { _ in
            // Accept only what is dragged from the device pane.
            guard !state.draggingRemote.isEmpty else { return false }
            let items = state.draggingRemote
            state.draggingRemote = []
            state.download(items)
            return true
        })
    }

    @ViewBuilder
    private func menu(for item: LocalItem) -> some View {
        let items = state.selectedLocal(orItem: item)
        Button(L("Открыть")) { state.openMac(item) }
        Button(L("Быстрый просмотр")) {
            state.activeSide = .mac
            if !state.macSelection.contains(item.url) { state.macSelection = [item.url] }
            state.quickLook()
        }
        Button(items.count > 1 ? L("Отправить на устройство (%d)", items.count) : L("Отправить на устройство")) {
            state.handleDrop(items.map(\.url))
        }
        .disabled(state.device == nil)
        Button(L("Переименовать по шаблону…")) { state.renameRequest = RenameRequest(local: items) }
        Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
        Divider()
        Button(L("Переместить в Корзину"), role: .destructive) { state.trashMac(items) }
    }

    private var displayPath: String {
        state.macURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var favorites: [(String, URL)] {
        let fm = FileManager.default
        return [
            (L("Загрузки"), fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]),
            (L("Рабочий стол"), fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]),
            (L("Документы"), fm.urls(for: .documentDirectory, in: .userDomainMask)[0]),
            (L("Изображения"), fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]),
            (L("Фото с устройств"), AppSettings.shared.photosFolder),
            (L("Домой"), fm.homeDirectoryForCurrentUser),
        ]
    }
}

// MARK: - Device

struct DevicePane: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var favorites = FavoritesStore.shared
    @Environment(\.palette) private var p
    @Environment(\.isSnapshot) private var snap
    @State private var targeted = false
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool
    var snapshotWidth: CGFloat = 500

    var body: some View {
        PaneShell(isTargeted: targeted) {
            header
        } content: {
            VStack(spacing: 0) {
                if state.device != nil, !state.searchText.isEmpty || state.deepResults != nil { searchBar }
                content
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard !searchFocused else { return .ignored }
            state.activeSide = .device
            state.quickLook()
            return .handled
        }
        .modifier(DropTarget(types: [.fileURL], targeted: $targeted) { providers in
            guard state.device != nil else { return false }
            loadURLs(providers) { state.handleDrop($0) }
            return true
        })
        .alert(L("Новая папка"), isPresented: $state.askNewFolder) {
            TextField(L("Название"), text: $state.dialogText)
            Button(L("Создать")) { state.createAndroidFolder(state.dialogText.trimmingCharacters(in: .whitespaces)) }
            Button(L("Отмена"), role: .cancel) {}
        }
        .alert(L("Переименовать"), isPresented: Binding(get: { state.renaming != nil },
                                                        set: { if !$0 { state.renaming = nil } })) {
            TextField(L("Название"), text: $state.dialogText)
            Button(L("Готово")) { if let r = state.renaming { state.renameAndroid(r, to: state.dialogText) } }
            Button(L("Отмена"), role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !state.toDelete.isEmpty },
                                                              set: { if !$0 { state.toDelete = [] } })) {
            Button(L("Удалить"), role: .destructive) { state.deleteAndroid(state.toDelete) }
        } message: {
            Text(L("Файлы удалятся с устройства без корзины."))
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if state.device?.kind == .console {
                JoyConMark(size: 16)
            } else {
                DroidMark(size: 16, glow: false)
            }
            if state.device != nil {
                IconButton(systemName: "chevron.left", help: L("Наверх")) { state.androidUp() }
                breadcrumbs
                if let fav = state.currentFavorite, state.androidPath.count > 1 {
                    let on = favorites.contains(fav, device: state.deviceKey)
                    IconButton(systemName: on ? "star.fill" : "star", help: on ? L("Убрать из избранного") : L("В избранное")) {
                        withAnimation(.spring(response: 0.3)) { state.toggleFavorite(fav) }
                    }
                    .foregroundStyle(on ? p.accent : p.muted)
                }
                Spacer(minLength: 4)
                if state.androidLoading { ProgressView().controlSize(.small) }
                searchField
                IconButton(systemName: state.viewMode == .grid ? "list.bullet" : "square.grid.2x2",
                           help: state.viewMode == .grid ? L("Списком") : L("Сеткой с превью")) {
                    withAnimation(.easeOut(duration: 0.2)) { state.viewMode = state.viewMode == .grid ? .list : .grid }
                }
                if state.device?.kind == .phone {
                    IconButton(systemName: state.showHidden ? "eye" : "eye.slash",
                               help: state.showHidden ? L("Скрыть служебные") : L("Показать служебные")) {
                        state.showHidden.toggle()
                    }
                }
                IconButton(systemName: "folder.badge.plus", help: L("Новая папка")) { state.beginNewFolder() }
                IconButton(systemName: "arrow.clockwise", help: L("Обновить")) { state.refreshAndroid() }
            } else {
                Text(L("Устройство")).font(AppFont.display(12))
                Spacer()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(p.muted)
            if snap {
                // A window snapshot doesn't draw text fields — show the placeholder as text.
                Text(L("Поиск")).font(AppFont.body(12)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
            TextField(L("Поиск"), text: $state.searchText)
                .textFieldStyle(.plain)
                .font(AppFont.body(12))
                .focused($searchFocused)
                .onSubmit { state.deepSearch() }
                .onChange(of: state.searchText) { _, v in
                    if v.isEmpty, state.deepResults != nil { state.clearSearch() }
                }
            }
            if !state.searchText.isEmpty {
                Button { state.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(p.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).frame(width: searchFocused || !state.searchText.isEmpty ? 170 : 96, height: 24)
        .background(Capsule().fill(p.bg.opacity(0.6)))
        .overlay(Capsule().stroke(searchFocused ? p.accent.opacity(0.7) : p.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            if state.deepResults != nil {
                if state.deepSearching { ProgressView().controlSize(.small) }
                Text(state.deepSearching
                     ? L("Ищем во вложенных… просмотрено %d", state.deepScanned)
                     : L("Найдено во вложенных: %d", state.deepResults?.count ?? 0))
                    .font(AppFont.body(11)).foregroundStyle(p.muted)
                Spacer()
                if state.deepSearching { Chip(title: L("Стоп")) { state.searchToken?.cancel(); state.deepSearching = false } }
                Chip(title: L("Готово")) { state.clearSearch() }
            } else {
                Text(L("В этой папке: %d", state.androidRows.count)).font(AppFont.body(11)).foregroundStyle(p.muted)
                Spacer()
                Chip(title: L("Искать во вложенных"), icon: "magnifyingglass") { state.deepSearch() }
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(p.hover.opacity(0.5))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state.connection {
        case .searching:
            if state.nintendoWithoutMTP {
                Hint(icon: "gamecontroller", title: L("Switch подключена, но DBI не в режиме MTP"),
                     lines: [L("На Switch: DBI → «Run MTP responder»"), L("Wirrow подхватит её сам")])
            } else {
                Hint(icon: "cable.connector", title: L("Подключите устройство"),
                     lines: [L("Android: уведомление USB → «Передача файлов»"),
                             L("Switch: DBI → «Run MTP responder»")])
            }
        case .busy:
            Hint(icon: "exclamationmark.triangle", title: L("Устройство занято другой программой"),
                 lines: [L("Закройте «Захват изображений», «Фото»"), L("и Android File Transfer, если они открыты")])
        case .locked:
            Hint(icon: "lock", title: L("Разблокируйте телефон"),
                 lines: [state.device?.transport == .adb || AppSettings.shared.adbEnabled
                         ? L("и разрешите отладку по USB") : L("и выберите режим USB «Передача файлов»")])
        case .connected:
            let rows = state.androidRows
            if rows.isEmpty && !state.androidLoading && !state.deepSearching {
                if !state.searchText.isEmpty {
                    Hint(icon: "magnifyingglass", title: L("Ничего не нашлось"),
                         lines: [L("Нажмите «Искать во вложенных» или Return")])
                } else {
                    Hint(icon: "tray", title: L("Здесь пусто"), lines: [L("Перетащите файлы из Finder или панели Mac")])
                }
            } else if state.viewMode == .grid {
                GridBrowser(rows: rows, onFocus: { focused = true })
            } else {
                FileTable(snapshotWidth: snapshotWidth) { compact in
                    ForEach(rows) { row in
                        DeviceRow(row: row, compact: compact, onFocus: { focused = true })
                    }
                }
            }
        }
    }

    private var deleteTitle: String {
        let d = state.toDelete
        return d.count == 1 ? L("Удалить «%@»?", d[0].name) : L("Удалить объектов: %d?", d.count)
    }

    /// The path: the current folder in full, earlier ones shortened, the middle of a long path — "…".
    private var breadcrumbs: some View {
        let path = state.androidPath
        let shown: [(Int, Crumb)] = path.count > 3
            ? [(0, path[0]), (-1, Crumb(id: 0, name: "…"))] + path.enumerated().suffix(2).map { ($0.offset, $0.element) }
            : path.enumerated().map { ($0.offset, $0.element) }
        return HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { n, pair in
                let (i, c) = pair
                if n > 0 { Text("/").foregroundStyle(p.muted.opacity(0.6)) }
                let last = i == path.count - 1
                Button(c.name) { if i >= 0 { state.goToCrumb(i) } else { state.goToCrumb(path.count - 3) } }
                    .buttonStyle(.plain)
                    .foregroundStyle(last ? p.text : p.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: last ? 220 : 90, alignment: .leading)
                    .fixedSize(horizontal: last, vertical: false)
                    .help(c.name)
            }
        }
        .font(AppFont.body(12))
        .layoutPriority(1)
    }
}

/// Game title for DBI storages.
func gameTitle(_ item: RemoteItem, storage: StorageInfo?) -> (String?, String?) {
    guard let s = storage, s.isInstalledGames || s.isSaves else { return (nil, nil) }
    let g = GameName(item.name)
    guard g.hasID || s.isSaves else { return (nil, nil) }
    let sub = [g.titleID, g.version].compactMap { $0 }.joined(separator: " · ")
    return (g.title, sub.isEmpty ? nil : sub)
}

/// A device row: its own highlight state when dragging onto a folder.
struct DeviceRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var thumbs = Thumbnails.shared
    let row: RemoteRow
    let compact: Bool
    var onFocus: () -> Void = {}
    @State private var dropTarget = false

    var body: some View {
        let item = row.item
        let game = gameTitle(item, storage: state.currentStorage)
        FileTableRow(name: item.name, isFolder: item.isFolder, size: item.size, modified: item.modified,
                     depth: row.depth, expanded: row.path == nil ? state.isExpanded(item) : nil,
                     loading: state.isLoading(item),
                     selected: state.androidSelection.contains(item.id), dropTarget: dropTarget,
                     compact: compact, thumbnail: thumbs.image(for: item, device: state.deviceKey),
                     title: game.0, subtitle: row.path.map { "· " + $0 } ?? game.1,
                     onMac: state.isOnMac(item), onToggle: { state.toggleExpand(item) })
            .onAppear { thumbs.request(item, device: state.deviceKey, download: false) }
            .onTapGesture(count: 2) { item.isFolder ? state.openAndroid(item) : state.download([item]) }
            .onTapGesture {
                state.activeSide = .device
                onFocus()
                toggleSelection(&state.androidSelection, item.id)
            }
            .onDrag {
                state.draggingRemote = state.selectedRemote(orItem: item)
                return state.itemProvider(for: item, state: state)
            }
            .modifier(FolderDrop(enabled: item.isFolder, targeted: $dropTarget) { urls in
                state.handleDrop(urls, into: item)
            })
            .contextMenu { RemoteMenu(item: item) }
    }
}

/// The context menu of a file or folder on the device.
struct RemoteMenu: View {
    @EnvironmentObject private var state: AppState
    let item: RemoteItem

    var body: some View {
        let items = state.selectedRemote(orItem: item)
        if item.isFolder {
            Button(L("Открыть")) { state.openAndroid(item) }
            Button(state.isExpanded(item) ? L("Свернуть") : L("Развернуть")) { state.toggleExpand(item) }
            if let fav = state.favorite(for: item) {
                Button(FavoritesStore.shared.contains(fav, device: state.deviceKey) ? L("Убрать из избранного") : L("В избранное")) {
                    state.toggleFavorite(fav)
                }
            }
        } else {
            Button(L("Быстрый просмотр")) {
                if !state.androidSelection.contains(item.id) { state.androidSelection = [item.id] }
                state.activeSide = .device
                state.quickLook()
            }
        }
        Button(items.count > 1 ? L("Скачать на Mac (%d)", items.count) : L("Скачать на Mac")) { state.download(items) }
        if items.contains(where: { MediaKind.isMedia($0.name) }) {
            Button(L("Добавить в «Фото»")) { state.exportToPhotos(items) }
        }
        Divider()
        Button(L("Переименовать")) { state.beginRename(item) }.disabled(items.count > 1)
        Button(L("Переименовать по шаблону…")) { state.renameRequest = RenameRequest(remote: items) }
        Divider()
        Button(L("Удалить…"), role: .destructive) { state.toDelete = items }
    }
}

// MARK: - Grid with thumbnails (album, camera)

struct GridBrowser: View {
    @EnvironmentObject private var state: AppState
    let rows: [RemoteRow]
    var onFocus: () -> Void = {}

    var body: some View {
        Scrollable {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 10)], spacing: 12) {
                ForEach(rows) { row in GridCell(item: row.item, onFocus: onFocus) }
            }
            .padding(12)
        }
    }
}

struct GridCell: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var thumbs = Thumbnails.shared
    @Environment(\.palette) private var p
    let item: RemoteItem
    var onFocus: () -> Void = {}
    @State private var hover = false
    @State private var dropTarget = false

    var body: some View {
        let selected = state.androidSelection.contains(item.id)
        let game = gameTitle(item, storage: state.currentStorage)
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(p.hover)
                if let img = thumbs.image(for: item, device: state.deviceKey) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    Image(systemName: fileIcon(name: item.name, isFolder: item.isFolder))
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(item.isFolder ? p.accent : p.muted)
                }
                if MediaKind.isVideo(item.name) {
                    Image(systemName: "play.circle.fill").font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.9)).shadow(radius: 3).padding(6)
                }
                if state.isOnMac(item) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                        .foregroundStyle(p.ok).background(Circle().fill(p.surface)).padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected || dropTarget ? p.accent : (hover ? p.line : .clear), lineWidth: selected ? 2 : 1))
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            Text(game.0 ?? item.name).font(AppFont.body(11)).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(selected ? p.text : p.muted)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onAppear { thumbs.request(item, device: state.deviceKey, download: true) }
        .onTapGesture(count: 2) {
            if item.isFolder { state.openAndroid(item) } else {
                state.androidSelection = [item.id]
                state.activeSide = .device
                state.quickLook()
            }
        }
        .onTapGesture {
            state.activeSide = .device
            onFocus()
            toggleSelection(&state.androidSelection, item.id)
        }
        .onDrag {
            state.draggingRemote = state.selectedRemote(orItem: item)
            return state.itemProvider(for: item, state: state)
        }
        .modifier(FolderDrop(enabled: item.isFolder, targeted: $dropTarget) { urls in state.handleDrop(urls, into: item) })
        .contextMenu { RemoteMenu(item: item) }
    }
}

/// The pane's drop zone. Not needed in a window snapshot: ImageRenderer draws it as yellow corners.
struct DropTarget: ViewModifier {
    @Environment(\.isSnapshot) private var snap
    let types: [UTType]
    @Binding var targeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if snap { content } else { content.onDrop(of: types, isTargeted: $targeted, perform: perform) }
    }
}

/// Drop files right onto a folder in the list.
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

/// Gets file URLs from dragged items.
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
