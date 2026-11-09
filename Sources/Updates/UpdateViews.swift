import SwiftUI

/// The update card on top of the window: slides in from the top, stages blend into each other.
struct UpdateOverlay: View {
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.palette) private var p

    private var modal: Bool {
        switch updates.phase {
        case .found, .ready, .failed: true
        default: false
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if modal {
                Rectangle().fill(Color.black.opacity(0.28))
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {}
            }
            if updates.phase != .hidden {
                UpdateCard()
                    .padding(.top, 54)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: updates.phase.key)
        .animation(.easeOut(duration: 0.2), value: modal)
    }
}

struct UpdateCard: View {
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.palette) private var p

    private var compact: Bool {
        switch updates.phase {
        case .checking, .upToDate, .installed: true
        default: false
        }
    }

    var body: some View {
        Group {
            if compact { toast } else { full }
        }
        .background(RoundedRectangle(cornerRadius: compact ? 999 : 16, style: .continuous).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: compact ? 999 : 16, style: .continuous).stroke(p.line, lineWidth: 1))
        .foregroundStyle(p.text)
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: updates.phase)
    }

    // MARK: Small pill: checking, "latest version", "updated"

    private var toast: some View {
        HStack(spacing: 10) {
            switch updates.phase {
            case .checking:
                ProgressView().controlSize(.small)
                Text(L("Проверяем обновления…"))
            case .upToDate:
                DrawnCheck(size: 16, color: p.ok)
                Text(L("У вас последняя версия — %@", updates.currentVersion))
            case .installed(let v):
                DrawnCheck(size: 16, color: p.ok)
                Text(L("Wirrow обновлён до %@", v))
            default:
                EmptyView()
            }
        }
        .font(AppFont.body(13, .medium))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .transition(.opacity)
        .id(updates.phase.key)
    }

    // MARK: Big card

    private var full: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                FloatingDroid()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(AppFont.display(15))
                    Text(subtitle).font(AppFont.body(12)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 0)
            }

            Group {
                switch updates.phase {
                case .found(let info): notes(info)
                case .downloading(let r, let t):
                    progress(value: t == 0 ? 0 : Double(r) / Double(t),
                             caption: t == 0 ? L("Скачиваем…") : "Скачиваем · \(formatBytes(r)) из \(formatBytes(t))")
                case .extracting(let v): progress(value: v, caption: L("Распаковываем…"))
                case .installing: progress(value: 1, caption: L("Устанавливаем и перезапускаем…"), busy: true)
                case .ready(let info): notes(info)
                case .failed(let m):
                    Text(m).font(AppFont.body(12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                default: EmptyView()
                }
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
            .id(updates.phase.key)

            buttons
        }
        .padding(18)
        .frame(width: 460)
    }

    private var title: String {
        switch updates.phase {
        case .found(let i), .ready(let i): L("Доступен Wirrow %@", i.version)
        case .downloading, .extracting: L("Скачиваем обновление")
        case .installing: L("Почти готово")
        case .failed: L("Не удалось обновить")
        default: ""
        }
    }

    private var subtitle: String {
        switch updates.phase {
        case .found(let i):
            L("У вас %@", updates.currentVersion) + (i.size > 0 ? " · \(formatBytes(i.size))" : "")
        case .ready: L("Обновление скачано и готово к установке")
        case .downloading, .extracting: L("Можно продолжать работать")
        case .installing: L("Wirrow перезапустится сам")
        case .failed: L("Попробуйте позже или скачайте с GitHub")
        default: ""
        }
    }

    @ViewBuilder
    private func notes(_ info: UpdateInfo) -> some View {
        if !info.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Что нового")).font(AppFont.body(11, .medium)).foregroundStyle(p.muted)
                ForEach(Array(info.notes.prefix(6).enumerated()), id: \.offset) { i, line in
                    StaggeredNote(text: line, index: i)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.hover.opacity(0.6)))
        }
    }

    private func progress(value: Double, caption: String, busy: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShimmerTrack(value: value, busy: busy)
            HStack {
                Text(caption)
                Spacer()
                if !busy { Text("\(Int(value * 100))%").monospacedDigit() }
            }
            .font(AppFont.body(11)).foregroundStyle(p.muted)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            switch updates.phase {
            case .found:
                GhostButton(title: L("Пропустить эту версию")) { updates.skip() }
                Spacer()
                Chip(title: L("Позже")) { updates.later() }
                AccentButton(title: L("Обновить сейчас")) { updates.install() }
            case .ready:
                Spacer()
                Chip(title: L("Позже")) { updates.later() }
                AccentButton(title: L("Перезапустить и обновить")) { updates.install() }
            case .downloading:
                Spacer()
                Chip(title: L("Отменить")) { updates.cancel() }
            case .failed:
                Link(L("Открыть страницу версий"), destination: URL(string: "https://github.com/Q7N3T/wirrow/releases")!)
                    .font(AppFont.body(12))
                Spacer()
                AccentButton(title: L("Понятно")) { updates.close() }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Animated elements

/// A droid that floats and glows softly.
struct FloatingDroid: View {
    @State private var up = false

    var body: some View {
        DroidMark(size: 40, glow: false)
            .shadow(color: Color(hex: 0xE9B949).opacity(up ? 0.6 : 0.25), radius: up ? 14 : 6)
            .offset(y: up ? -3 : 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

/// A changelog item that appears with a staggered delay.
struct StaggeredNote: View {
    @Environment(\.palette) private var p
    @Environment(\.isSnapshot) private var snap
    let text: String
    let index: Int
    @State private var shown = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(p.accent).frame(width: 5, height: 5).offset(y: -2)
            Text(text).font(AppFont.body(12)).fixedSize(horizontal: false, vertical: true)
        }
        .opacity(shown || snap ? 1 : 0)
        .offset(x: shown || snap ? 0 : -8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.12 + Double(index) * 0.06)) { shown = true }
        }
    }
}

/// A progress bar with a moving shine.
struct ShimmerTrack: View {
    @Environment(\.palette) private var p
    var value: Double
    var busy = false
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { g in
            let w = g.size.width * min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(p.line)
                Capsule().fill(p.accent)
                    .frame(width: max(8, w))
                    .overlay(
                        LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 60)
                            .offset(x: phase * max(8, w))
                            .blendMode(.plusLighter)
                    )
                    .clipShape(Capsule())
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 8)
        .opacity(busy ? 0.85 : 1)
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
        }
    }
}

/// A checkmark that draws itself.
struct DrawnCheck: View {
    @Environment(\.isSnapshot) private var snap
    var size: CGFloat = 16
    var color: Color
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: drawn).stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape().trim(from: 0, to: max(0, drawn * 1.4 - 0.4))
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .onAppear {
            if snap { drawn = 1 } else { withAnimation(.easeOut(duration: 0.55)) { drawn = 1 } }
        }
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// The main button: a golden pill.
struct AccentButton: View {
    @Environment(\.palette) private var p
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.body(12, .medium))
                .foregroundStyle(p.ink)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(p.accent).brightness(hover ? 0.06 : 0))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// A quiet text button.
struct GhostButton: View {
    @Environment(\.palette) private var p
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(AppFont.body(12)).foregroundStyle(hover ? p.text : p.muted)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
