import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @AppStorage("theme") private var theme: ThemeMode = .system

    var body: some View {
        VStack(spacing: 0) {
            topBar
            DeviceCard()
                .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            if state.connection.info != nil {
                quickFolders.padding(.horizontal, 18).padding(.bottom, 12)
            }
            HStack(spacing: 12) {
                MacPane()
                AndroidPane()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            TransferPanel()
        }
        .background(p.bg)
        .foregroundStyle(p.text)
        .font(AppFont.body())
        .ignoresSafeArea(.container, edges: .top)
        .alert("Что-то пошло не так", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // Место под «светофор» окна.
            Color.clear.frame(width: 66, height: 1)
            DroidMark(size: 20)
            Text("Shuttle").font(AppFont.display(14, .bold))
            Spacer()
            HStack(spacing: 6) {
                ForEach(ThemeMode.allCases) { m in
                    Chip(title: m.title, isOn: theme == m) { theme = m }
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
        .padding(.bottom, 12)
    }

    private var quickFolders: some View {
        Scrollable(axis: .horizontal) {
            HStack(spacing: 6) {
                ForEach(QuickFolder.android) { q in
                    Chip(title: q.title, icon: q.icon, isOn: state.activeQuick == q.id) {
                        state.openQuick(q)
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
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(p.surface)
                RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1)
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(state.connection.info != nil ? p.accent : p.muted)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppFont.display(14))
                Text(subtitle).font(AppFont.body(12)).foregroundStyle(p.muted).lineLimit(2)
            }
            Spacer(minLength: 12)

            if let info = state.connection.info {
                VStack(alignment: .trailing, spacing: 6) {
                    ProgressTrack(value: info.capacity == 0 ? 0 : 1 - Double(info.free) / Double(info.capacity),
                                  color: p.muted)
                        .frame(width: 140)
                    HStack(spacing: 10) {
                        if let b = info.battery {
                            Label("\(b)%", systemImage: batteryIcon(b))
                                .font(AppFont.body(11)).foregroundStyle(p.muted)
                        }
                        Text("\(formatBytes(info.free)) свободно")
                            .font(AppFont.body(11)).foregroundStyle(p.muted)
                    }
                }
            }
            statusPill
        }
    }

    private var title: String {
        state.connection.info?.name ?? "Телефон не подключён"
    }

    private var subtitle: String {
        switch state.connection {
        case .connected(let i): "USB · \(i.storageName) · \(formatBytes(i.capacity))"
        case .searching: "Подключите Android кабелем и выберите «Передача файлов»"
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
