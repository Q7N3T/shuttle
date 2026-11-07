import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
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
        .toolbar {
            ToolbarItem(placement: .navigation) { brand }.withoutGlass()
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            ToolbarItem(placement: .automatic) { controls }.withoutGlass()
        }
        .transparentToolbar()
        .background(WindowChrome())
        .alert("Что-то пошло не так", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button("Понятно", role: .cancel) {}
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
            IconButton(systemName: "sidebar.left", help: showMac ? "Скрыть панель Mac" : "Показать панель Mac",
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

    /// Вкладки разделов (SD Card, Nand USER…) и быстрые папки телефона.
    private func tabs(_ device: DeviceInfo) -> some View {
        Scrollable(axis: .horizontal) {
            HStack(spacing: 6) {
                if device.storages.count > 1 || device.kind == .console {
                    ForEach(device.storages) { s in
                        Chip(title: s.name, icon: s.icon, isOn: state.storageID == s.id) {
                            state.selectStorage(s.id)
                        }
                        .help(s.capacity > 0 ? "\(formatBytes(s.free)) свободно из \(formatBytes(s.capacity))" : s.name)
                    }
                }
                if device.kind == .phone {
                    if device.storages.count > 1 {
                        Rectangle().fill(p.line).frame(width: 1, height: 18).padding(.horizontal, 4)
                    }
                    ForEach(QuickFolder.android) { q in
                        Chip(title: q.title, icon: q.icon, isOn: state.activeQuick == q.id) {
                            state.openQuick(q)
                        }
                    }
                }
            }
        }
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
                if state.device?.kind == .console {
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
                            Text("\(formatBytes(s.free)) свободно")
                                .font(AppFont.body(11)).foregroundStyle(p.muted)
                        }
                    }
                }
            }
            statusPill
        }
    }

    private var title: String {
        state.device?.name ?? "Устройство не подключено"
    }

    private var subtitle: String {
        switch state.connection {
        case .connected(let i):
            i.kind == .console
                ? "USB · MTP · разделов: \(i.storages.count)"
                : "USB · \(state.currentStorage?.name ?? i.storageName) · \(formatBytes(state.currentStorage?.capacity ?? i.capacity))"
        case .searching: "Android или Switch с DBI по кабелю USB"
        case .busy: MTPError.busy.localizedDescription
        case .locked: MTPError.locked.localizedDescription
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = switch state.connection {
        case .connected: ("Подключён", p.ok)
        case .searching: ("Ищем…", p.muted)
        case .busy: ("Занят", p.danger)
        case .locked: ("Заблокирован", p.accent)
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
