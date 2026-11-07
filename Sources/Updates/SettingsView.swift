import SwiftUI

/// Настройки (⌘,): обновления и оформление.
struct SettingsView: View {
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.palette) private var p
    @AppStorage("theme") private var theme: ThemeMode = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                DroidMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuttle").font(AppFont.display(15, .bold))
                    Text("Версия \(updates.currentVersion)").font(AppFont.body(12)).foregroundStyle(p.muted)
                }
            }

            section("Обновления") {
                SettingToggle(title: "Проверять обновления автоматически",
                              hint: "Раз в день. Новую версию покажем в окне Shuttle.",
                              isOn: $updates.automaticallyChecks)
                SettingToggle(title: "Скачивать и устанавливать сами",
                              hint: "Обновление поставится при следующем запуске.",
                              isOn: $updates.automaticallyInstalls)
                    .disabled(!updates.automaticallyChecks)
                    .opacity(updates.automaticallyChecks ? 1 : 0.5)
                HStack(spacing: 8) {
                    Chip(title: "Проверить сейчас", icon: "arrow.triangle.2.circlepath") { updates.checkNow() }
                    if updates.hasSkippedVersion {
                        Chip(title: "Снова показывать пропущенные", icon: "arrow.uturn.backward") {
                            withAnimation(.easeOut(duration: 0.2)) { updates.resetSkipped() }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                Link(destination: URL(string: "https://github.com/Q7N3T/shuttle/releases")!) {
                    Label("История версий и старые сборки", systemImage: "clock.arrow.circlepath")
                        .font(AppFont.body(12))
                }
            }

            section("Оформление") {
                HStack(spacing: 6) {
                    ForEach(ThemeMode.allCases) { m in
                        Chip(title: m.title, icon: m.icon, isOn: theme == m) { theme = m }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(p.bg)
        .foregroundStyle(p.text)
        .tint(p.accent)
        .onAppear { updates.refreshSkipped() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(AppFont.display(12)).foregroundStyle(p.muted)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
        }
    }
}

/// Строка с переключателем-пилюлей и подсказкой.
struct SettingToggle: View {
    @Environment(\.palette) private var p
    let title: String
    var hint: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isOn.toggle() } } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.body(13))
                    if let hint { Text(hint).font(AppFont.body(11)).foregroundStyle(p.muted) }
                }
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? p.accent : p.line).frame(width: 36, height: 20)
                    Circle().fill(isOn ? p.ink : p.muted).frame(width: 14, height: 14).padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
