import SwiftUI

/// Все окна-листы приложения в одном месте.
struct AppSheets: ViewModifier {
    @EnvironmentObject private var state: AppState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.showHistory) { Themed { HistorySheet() } }
            .sheet(isPresented: $state.showSync) { Themed { SyncSheet() } }
            .sheet(isPresented: $state.showDuplicates) { Themed { DuplicatesSheet() } }
            .sheet(item: $state.renameRequest) { r in Themed { RenameSheet(request: r) } }
            .sheet(item: $state.pendingInstall) { i in Themed { InstallSheet(install: i) } }
            .sheet(isPresented: Binding(get: { state.pendingHomebrew != nil }, set: { if !$0 { state.pendingHomebrew = nil } })) {
                Themed { HomebrewSheet() }
            }
            .sheet(isPresented: Binding(get: { state.pendingAPK != nil }, set: { if !$0 { state.pendingAPK = nil } })) {
                Themed { APKSheet() }
            }
            .sheet(isPresented: Binding(get: { state.atmosphere != nil }, set: { if !$0 { state.atmosphere = nil } })) {
                Themed { AtmosphereSheet() }
            }
    }
}

/// Лист наследует тему окна, но палитру надо передать явно.
struct Themed<Content: View>: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("theme") private var theme: ThemeMode = .system
    @ViewBuilder var content: Content
    var body: some View {
        ThemedRoot(theme: theme) { content }.environmentObject(state)
    }
}

/// Общая рамка листа.
struct SheetShell<Body: View, Buttons: View>: View {
    @Environment(\.palette) private var p
    let icon: String
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 520
    @ViewBuilder var content: Body
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(p.accent.opacity(0.15))
                    Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(p.accent)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.display(15))
                    if let subtitle { Text(subtitle).font(AppFont.body(12)).foregroundStyle(p.muted) }
                }
            }
            content
            HStack(spacing: 8) { buttons }
        }
        .padding(22)
        .frame(width: width)
        .background(p.bg)
        .foregroundStyle(p.text)
    }
}

// MARK: - История

struct HistorySheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell(icon: "clock.arrow.circlepath", title: L("История передач"),
                   subtitle: L("Последние %d записей", history.entries.count), width: 600) {
            if history.entries.isEmpty {
                Text(L("Пока пусто — здесь появится всё, что вы копировали.")).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                        ForEach(history.grouped, id: \.day) { g in
                            Section {
                                ForEach(g.items) { e in HistoryRow(entry: e) }
                            } header: {
                                Text(formatDay(g.day)).font(AppFont.body(11, .medium)).foregroundStyle(p.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).background(p.bg)
                            }
                        }
                    }
                }
                .frame(height: 380)
            }
        } buttons: {
            GhostButton(title: L("Очистить историю")) { history.clear() }
            Spacer()
            AccentButton(title: L("Готово")) { dismiss() }
        }
    }

    private func formatDay(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return L("Сегодня") }
        if Calendar.current.isDateInYesterday(d) { return L("Вчера") }
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.english ? "en_US" : "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: d)
    }
}

struct HistoryRow: View {
    @Environment(\.palette) private var p
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.toMac ? "arrow.left" : "arrow.right").foregroundStyle(p.accent).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text([entry.device, entry.date.formatted(date: .omitted, time: .shortened), formatBytes(entry.bytes)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(AppFont.body(11)).foregroundStyle(p.muted)
            }
            Spacer()
            if !entry.ok {
                Text(L("Ошибка")).font(AppFont.body(11)).foregroundStyle(p.danger).help(entry.note ?? "")
            } else if let path = entry.macPath, FileManager.default.fileExists(atPath: path) {
                IconButton(systemName: "magnifyingglass", help: L("Показать в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
        .font(AppFont.body(12))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
    }
}

// MARK: - Синхронизация

struct SyncSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SyncStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rules = store.rules(for: state.deviceKey)
        SheetShell(icon: "arrow.triangle.2.circlepath", title: L("Синхронизация папок"),
                   subtitle: L("Новые файлы с устройства → в папку на Mac. Ничего не удаляется."), width: 600) {
            if rules.isEmpty {
                VStack(spacing: 8) {
                    Text(L("Правил пока нет")).font(AppFont.display(13))
                    Text(L("Откройте нужную папку на устройстве (например, «Камера») и нажмите «Добавить текущую папку»."))
                        .font(AppFont.body(12)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                VStack(spacing: 8) {
                    ForEach(rules) { r in
                        HStack(spacing: 10) {
                            Image(systemName: "folder").foregroundStyle(p.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(r.storage) / \(r.title)").lineLimit(1)
                                Text("→ " + r.localPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                                     + (r.lastRun.map { " · " + L("последний раз %@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? ""))
                                    .font(AppFont.body(11)).foregroundStyle(p.muted).lineLimit(1)
                            }
                            Spacer()
                            Chip(title: L("Сейчас"), icon: "play.fill") { state.runSyncs([r]); dismiss() }
                            IconButton(systemName: "trash", help: L("Удалить правило")) { store.remove(r) }
                        }
                        .font(AppFont.body(12))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
                    }
                }
            }
            SettingToggle(title: L("Синхронизировать при подключении"),
                          hint: L("Как только телефон подключится, Shuttle заберёт новое сам."),
                          isOn: $settings.autoSync)
        } buttons: {
            Chip(title: L("Добавить текущую папку"), icon: "plus") { state.addSyncRuleForCurrentFolder() }
                .disabled(state.device == nil)
            if !rules.isEmpty {
                Chip(title: L("Запустить все"), icon: "play.fill") { state.runSyncs(rules); dismiss() }
            }
            Spacer()
            AccentButton(title: L("Готово")) { dismiss() }
        }
    }
}

// MARK: - Дубли

struct DuplicatesSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<UInt32> = []
    @State private var confirm = false

    var body: some View {
        SheetShell(icon: "square.on.square", title: L("Уже есть на Mac"),
                   subtitle: state.duplicates.isEmpty ? L("Дублей не нашлось")
                       : L("Файлов: %d · %@", state.duplicates.count,
                           formatBytes(state.duplicates.reduce(0) { $0 + $1.size }))) {
            if !state.duplicates.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.duplicates) { d in
                            Button {
                                if picked.contains(d.id) { picked.remove(d.id) } else { picked.insert(d.id) }
                            } label: {
                                HStack {
                                    Image(systemName: picked.contains(d.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(picked.contains(d.id) ? p.accent : p.muted)
                                    Text(d.name).lineLimit(1)
                                    Spacer()
                                    Text(formatBytes(d.size)).foregroundStyle(p.muted)
                                }
                                .font(AppFont.body(12)).padding(.horizontal, 10).frame(height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
            }
        } buttons: {
            if !state.duplicates.isEmpty {
                GhostButton(title: picked.count == state.duplicates.count ? L("Снять выбор") : L("Выбрать все")) {
                    picked = picked.count == state.duplicates.count ? [] : Set(state.duplicates.map(\.id))
                }
            }
            Spacer()
            Chip(title: L("Закрыть")) { dismiss() }
            if !picked.isEmpty {
                AccentButton(title: L("Удалить с устройства: %d", picked.count)) { confirm = true }
            }
        }
        .confirmationDialog(L("Удалить %d файлов с устройства?", picked.count), isPresented: $confirm) {
            Button(L("Удалить"), role: .destructive) {
                state.deleteAndroid(state.duplicates.filter { picked.contains($0.id) })
                dismiss()
            }
        } message: {
            Text(L("Копии на Mac останутся. Удаление с устройства без корзины."))
        }
    }
}

// MARK: - Пакетное переименование

struct RenameSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let request: RenameRequest
    @State private var pattern = RenamePattern()

    var body: some View {
        let inputs = request.inputs
        let names = pattern.apply(inputs)
        SheetShell(icon: "character.cursor.ibeam", title: L("Переименовать по шаблону"),
                   subtitle: L("Объектов: %d", inputs.count), width: 620) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("Шаблон"), text: $pattern.template)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    ForEach(["{name}", "{n}", "{date}", "{ext}"], id: \.self) { t in
                        Chip(title: t) { pattern.template += (pattern.template.hasSuffix(" ") || pattern.template.isEmpty ? "" : " ") + t }
                    }
                    Spacer()
                    Stepper(L("с %d", pattern.start), value: $pattern.start, in: 0...9999).font(AppFont.body(12))
                }
                Text(L("{name} — имя, {n} — номер, {date} — дата изменения, {ext} — расширение"))
                    .font(AppFont.body(11)).foregroundStyle(p.muted)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(zip(inputs, names).enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 8) {
                            Text(pair.0.name).foregroundStyle(p.muted).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(p.accent)
                            Text(pair.1).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(AppFont.body(12)).padding(.horizontal, 10).frame(height: 24)
                    }
                }
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        } buttons: {
            Spacer()
            Chip(title: L("Отмена")) { dismiss() }
            AccentButton(title: L("Переименовать")) { state.applyRename(request, pattern: pattern); dismiss() }
        }
    }
}

// MARK: - Switch: установка игр

struct InstallSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let install: PendingInstall

    var body: some View {
        let sd = state.device?.storage(where: \.isSDCard)
        let nand = state.device?.storage { $0.name.lowercased() == "nand user" }
        SheetShell(icon: "gamecontroller", title: L("Установить через DBI"),
                   subtitle: L("Игр: %d · %@", install.files.count, formatBytes(install.size))) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(install.files, id: \.self) { f in
                    let g = GameName(f.deletingPathExtension().lastPathComponent)
                    HStack {
                        Image(systemName: "gamecontroller").foregroundStyle(p.accent)
                        Text(g.title).lineLimit(1)
                        if let id = g.titleID { Text(id).font(AppFont.body(10)).foregroundStyle(p.muted) }
                        Spacer()
                        Text(formatBytes(localSize(f))).foregroundStyle(p.muted)
                    }
                    .font(AppFont.body(12))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
            Text(L("Shuttle передаст файлы в DBI, а установит их сама Switch. Не отключайте кабель до конца."))
                .font(AppFont.body(12)).foregroundStyle(p.muted)
            if let sd, sd.capacity > 0, install.size > sd.free {
                Label(L("На SD-карте мало места: свободно %@", formatBytes(sd.free)), systemImage: "exclamationmark.triangle")
                    .font(AppFont.body(12)).foregroundStyle(p.danger)
            }
        } buttons: {
            GhostButton(title: L("Просто скопировать")) { state.upload(install.files); dismiss() }
            Spacer()
            Chip(title: L("Отмена")) { dismiss() }
            if nand != nil {
                Chip(title: L("На NAND")) { state.installGames(install.files, toNAND: true); dismiss() }
            }
            AccentButton(title: L("На SD-карту")) { state.installGames(install.files, toNAND: false); dismiss() }
        }
    }
}

struct HomebrewSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var plan: [HomebrewLayout.Placement] = []
    @State private var unpacked: URL?
    @State private var failed: String?

    var body: some View {
        let zip = state.pendingHomebrew
        SheetShell(icon: "shippingbox", title: L("Установить homebrew"),
                   subtitle: zip?.lastPathComponent) {
            if let failed {
                Text(failed).foregroundStyle(p.danger).font(AppFont.body(12))
            } else if plan.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Куда попадёт на SD-карте")).font(AppFont.body(11, .medium)).foregroundStyle(p.muted)
                    ForEach(Array(plan.enumerated()), id: \.offset) { _, pl in
                        HStack(spacing: 6) {
                            Image(systemName: fileIcon(name: pl.local.lastPathComponent, isFolder: pl.local.hasDirectoryPath))
                                .foregroundStyle(p.accent).frame(width: 16)
                            Text(pl.local.lastPathComponent)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(p.muted)
                            Text("/" + (pl.remoteFolder + [pl.local.lastPathComponent]).joined(separator: "/"))
                                .foregroundStyle(p.muted).lineLimit(1).truncationMode(.middle)
                        }
                        .font(AppFont.body(12))
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
                Text(L("Совпадающие файлы на SD-карте будут заменены новыми."))
                    .font(AppFont.body(12)).foregroundStyle(p.muted)
            }
        } buttons: {
            GhostButton(title: L("Просто скопировать архив")) {
                if let zip { state.upload([zip]) }
                dismiss()
            }
            Spacer()
            Chip(title: L("Отмена")) { dismiss() }
            AccentButton(title: L("Разложить по папкам")) {
                if let zip { state.installHomebrew(zip) }
                dismiss()
            }
            .disabled(plan.isEmpty)
        }
        .task {
            guard let zip = state.pendingHomebrew else { return }
            do {
                let dir = try HomebrewLayout.unzip(zip)
                unpacked = dir
                plan = HomebrewLayout.plan(unpacked: dir)
                if plan.isEmpty { failed = L("Архив пустой") }
            } catch { failed = error.localizedDescription }
        }
        .onDisappear { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
    }
}

struct AtmosphereSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = state.atmosphere
        SheetShell(icon: "sparkles", title: L("Обновить Atmosphère"),
                   subtitle: r.map { L("Последняя версия: %@", $0.version) + ($0.published.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "") }) {
            VStack(alignment: .leading, spacing: 8) {
                step("1", L("Скопируем папки atmosphere и bootloader с SD-карты на Mac"))
                step("2", L("Скачаем Atmosphère и fusee.bin с GitHub"))
                step("3", L("Разложим файлы по SD-карте с заменой старых"))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
            Text(L("После обновления перезагрузите Switch в Atmosphère. Если что-то пойдёт не так, копия старой версии будет в «Документы → Shuttle → Резервные копии Switch»."))
                .font(AppFont.body(12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let r { Link(L("Что нового в %@", r.version), destination: r.notesURL).font(AppFont.body(12)) }
        } buttons: {
            Spacer()
            Chip(title: L("Отмена")) { dismiss() }
            AccentButton(title: L("Обновить")) { if let r { state.updateAtmosphere(r) }; dismiss() }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(AppFont.body(11, .medium)).foregroundStyle(p.ink)
                .frame(width: 18, height: 18).background(Circle().fill(p.accent))
            Text(text).font(AppFont.body(12))
        }
    }
}

// MARK: - Android: APK

struct APKSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let apks = state.pendingAPK ?? []
        SheetShell(icon: "shippingbox", title: L("Установить приложение на телефон?"),
                   subtitle: apks.map(\.lastPathComponent).joined(separator: ", ")) {
            Text(L("Телефон подключён по ADB — Shuttle может сразу установить APK."))
                .font(AppFont.body(12))
        } buttons: {
            GhostButton(title: L("Только скопировать")) {
                state.uploadTo(path: ["Download"], urls: apks, label: "APK")
                dismiss()
            }
            Spacer()
            Chip(title: L("Отмена")) { dismiss() }
            AccentButton(title: L("Установить")) { state.installAPK(apks); dismiss() }
        }
    }
}
