import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var favorites = FavoritesStore.shared
    @Environment(\.palette) private var p
    @AppStorage("theme") private var theme: ThemeMode = .system
    @AppStorage("showMacPane") private var showMac = true
    @Environment(\.isSnapshot) private var snap

    var body: some View {
        VStack(spacing: 0) {
            // В окне шапка — это панель инструментов (см. toolbar ниже), и macOS сама
            // выравнивает её по кнопкам окна. В снимке панели нет — рисуем её копию.
            if snap {
                HStack { Color.clear.frame(width: 70, height: 1); brand; Spacer(); controls }
                    .padding(.horizontal, 14).frame(height: 52)
            }
            Rectangle().fill(p.line).frame(height: 1).padding(.bottom, 12)
            DeviceCard()
                .padding(.horizontal, 16).padding(.bottom, 10)
            if let device = state.device {
                tabs(device).padding(.horizontal, 16).padding(.bottom, 10)
            }
            HStack(spacing: 10) {
                if showMac {
                    MacPane(snapshotWidth: 470)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                DevicePane(snapshotWidth: showMac ? 470 : 1000)
            }
            .animation(.easeOut(duration: 0.18), value: showMac)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            TransferPanel()
        }
        .background(p.bg.ignoresSafeArea())
        .foregroundStyle(p.text)
        .font(AppFont.body())
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 150) }
        .toolbar {
            ToolbarItem(placement: .navigation) { brand }.withoutGlass()
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            ToolbarItem(placement: .automatic) { controls }.withoutGlass()
        }
        .transparentToolbar()
        .background(WindowChrome())
        .modifier(AppSheets())
        .alert(L("Что-то пошло не так"), isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button(L("Понятно"), role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    /// Слева в шапке: логотип и название.
    private var brand: some View {
        HStack(spacing: 10) {
            DroidMark(size: 24)
            Text("Shuttle").font(AppFont.display(16, .bold)).foregroundStyle(p.text)
        }
        .padding(.leading, 6)
        .fixedSize()
    }

    /// Справа в шапке: панель Mac и тема.
    private var controls: some View {
        HStack(spacing: 10) {
            IconButton(systemName: "sidebar.left", help: showMac ? L("Скрыть панель Mac") : L("Показать панель Mac"),
                       size: 30) {
                withAnimation(.easeOut(duration: 0.18)) { showMac.toggle() }
            }
            HStack(spacing: 2) {
                ForEach(ThemeMode.allCases) { m in
                    IconChip(systemName: m.icon, isOn: theme == m, help: m.title, width: 30, height: 26) { theme = m }
                }
            }
            .padding(3)
            .background(Capsule().fill(p.surface))
            .overlay(Capsule().stroke(p.line, lineWidth: 1))
        }
        .padding(.trailing, snap ? 0 : 8)
        .fixedSize()
    }

    /// Вкладки разделов (SD Card, Nand USER…), избранное и быстрые папки телефона.
    private func tabs(_ device: DeviceInfo) -> some View {
        Scrollable(axis: .horizontal) {
            HStack(spacing: 6) {
                if device.storages.count > 1 || device.kind == .console {
                    ForEach(device.storages) { s in
                        Chip(title: s.name, icon: s.icon, isOn: state.storageID == s.id && state.activeQuick == nil
                             && state.androidPath.count <= 1) {
                            state.selectStorage(s.id)
                        }
                        .help(s.capacity > 0 ? L("%@ свободно из %@", formatBytes(s.free), formatBytes(s.capacity)) : s.name)
                    }
                }
                let favs = favorites.list(device.key)
                if !favs.isEmpty {
                    divider
                    ForEach(favs) { f in
                        Chip(title: f.title, icon: "star.fill", isOn: state.activeQuick == "fav:" + f.id) {
                            state.openFavorite(f)
                        }
                        .help(f.storage + " / " + f.path.joined(separator: "/"))
                        .contextMenu {
                            Button(L("Убрать из избранного")) { state.toggleFavorite(f) }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                if device.kind == .phone {
                    if device.storages.count > 1 || !favs.isEmpty { divider }
                    ForEach(QuickFolder.android) { q in
                        Chip(title: q.title, icon: q.icon, isOn: state.activeQuick == q.id) {
                            state.openQuick(q)
                        }
                    }
                }
            }
            .animation(.spring(response: 0.3), value: favorites.list(device.key))
        }
    }

    private var divider: some View {
        Rectangle().fill(p.line).frame(width: 1, height: 18).padding(.horizontal, 4)
    }
}

/// Короткое сообщение внизу окна.
struct ToastView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            if let t = state.toast {
                HStack(spacing: 8) {
                    DrawnCheck(size: 14, color: p.accent)
                    Text(t).font(AppFont.body(12, .medium))
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(p.surface))
                .overlay(Capsule().stroke(p.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                .foregroundStyle(p.text)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.toast)
        .allowsHitTesting(false)
    }
}

struct DeviceCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(p.surface)
                RoundedRectangle(cornerRadius: 10).stroke(p.line, lineWidth: 1)
                if state.device?.kind == .console || state.nintendoWithoutMTP {
                    JoyConMark(size: 20)
                } else {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(state.device != nil ? p.accent : p.muted)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.display(13))
                Text(subtitle).font(AppFont.body(12)).foregroundStyle(p.muted).lineLimit(2)
            }
            Spacer(minLength: 12)

            if let info = state.device { actions(info) }

            if let info = state.device {
                VStack(alignment: .trailing, spacing: 5) {
                    if let s = state.currentStorage, s.capacity > 0 {
                        ProgressTrack(value: 1 - Double(s.free) / Double(s.capacity), color: p.muted, height: 5)
                            .frame(width: 130)
                    }
                    HStack(spacing: 10) {
                        if let b = info.battery {
                            Label("\(b)%", systemImage: batteryIcon(b))
                                .font(AppFont.body(11)).foregroundStyle(p.muted)
                        }
                        if let s = state.currentStorage, s.capacity > 0 {
                            Text(L("%@ свободно", formatBytes(s.free)))
                                .font(AppFont.body(11)).foregroundStyle(p.muted)
                        }
                    }
                }
            }
            statusPill
        }
        .animation(.spring(response: 0.35), value: state.newPhotos.count)
    }

    /// Быстрые действия для подключённого устройства.
    @ViewBuilder
    private func actions(_ info: DeviceInfo) -> some View {
        HStack(spacing: 6) {
            if info.kind == .phone {
                if !state.newPhotos.isEmpty {
                    Chip(title: L("С камеры: %d", state.newPhotos.count), icon: "photo.badge.arrow.down", isOn: true) {
                        state.importNewPhotos()
                    }
                    .help(L("Скачать фото и видео, которых ещё нет на Mac, в %@",
                            state.photosDestination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                    .transition(.scale.combined(with: .opacity))
                }
                if info.transport == .adb {
                    Chip(title: L("Снимок экрана"), icon: "camera.viewfinder") { state.takeScreenshot() }
                }
                Chip(title: L("Синхронизация"), icon: "arrow.triangle.2.circlepath") { state.showSync = true }
            } else {
                if info.storage(where: \.isSaves) != nil {
                    Chip(title: L("Сохранить сейвы"), icon: "tray.and.arrow.down") { state.backupSaves() }
                }
                Chip(title: state.atmosphereChecking ? L("Проверяем…") : "Atmosphère", icon: "sparkles") {
                    state.checkAtmosphere()
                }
                .disabled(state.atmosphereChecking)
            }
        }
    }

    private var title: String {
        if state.device == nil && state.nintendoWithoutMTP { return "Nintendo Switch" }
        return state.device?.name ?? L("Устройство не подключено")
    }

    private var subtitle: String {
        switch state.connection {
        case .connected(let i):
            i.kind == .console
                ? L("%@ · MTP · разделов: %d", i.transport == .mock ? L("Тест") : "USB", i.storages.count)
                : "\(i.transport == .adb ? "ADB" : (i.transport == .mock ? L("Тест") : "USB")) · \(state.currentStorage?.name ?? i.storageName) · \(formatBytes(state.currentStorage?.capacity ?? i.capacity))"
        case .searching:
            state.nintendoWithoutMTP ? L("Подключена, но DBI не в режиме MTP") : L("Android или Switch с DBI по кабелю USB")
        case .busy: MTPError.busy.localizedDescription
        case .locked: MTPError.locked.localizedDescription
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = switch state.connection {
        case .connected: (L("Подключён"), p.ok)
        case .searching: (state.nintendoWithoutMTP ? L("Нужен DBI") : L("Ищем…"), state.nintendoWithoutMTP ? p.accent : p.muted)
        case .busy: (L("Занят"), p.danger)
        case .locked: (L("Заблокирован"), p.accent)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(AppFont.body(12))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(Capsule().stroke(p.line, lineWidth: 1))
    }

    private func batteryIcon(_ b: Int) -> String {
        switch b {
        case ..<15: "battery.0percent"
        case ..<40: "battery.25percent"
        case ..<65: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
