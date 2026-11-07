import SwiftUI
import AppKit

/// Палитра из kino-na-vecher: сливовый фон, золотой акцент.
struct Palette {
    let bg, surface, hover, line, text, muted, accent, ink, ok, danger: Color

    static let dark = Palette(
        bg: Color(hex: 0x17121A), surface: Color(hex: 0x221A26), hover: Color(hex: 0x2B2130),
        line: Color(hex: 0x3A2E3F), text: Color(hex: 0xF2EAE0), muted: Color(hex: 0xA3959F),
        accent: Color(hex: 0xE9B949), ink: Color(hex: 0x2A1E05), ok: Color(hex: 0x7FC79A),
        danger: Color(hex: 0xE5766A))

    static let light = Palette(
        bg: Color(hex: 0xF6F1EA), surface: Color(hex: 0xFFFFFF), hover: Color(hex: 0xF1E9DE),
        line: Color(hex: 0xE3D8CB), text: Color(hex: 0x1F1822), muted: Color(hex: 0x7A6C76),
        accent: Color(hex: 0xE9B949), ink: Color(hex: 0x2A1E05), ok: Color(hex: 0x3E8E5E),
        danger: Color(hex: 0xC2493C))

    static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .dark : .light }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.dark }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Unbounded для заголовков, Golos Text для текста.
/// Если шрифты не положены в Resources/Fonts — аккуратный системный фолбэк.
enum AppFont {
    private static let hasUnbounded = NSFontManager.shared.availableMembers(ofFontFamily: "Unbounded") != nil
    private static let hasGolos = NSFontManager.shared.availableMembers(ofFontFamily: "Golos Text") != nil

    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        hasUnbounded
            ? .custom("Unbounded", size: size).weight(weight)
            : .system(size: size, weight: weight == .medium ? .semibold : .bold, design: .rounded)
    }

    static func body(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        hasGolos ? .custom("Golos Text", size: size).weight(weight) : .system(size: size, weight: weight)
    }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Авто"
        case .dark: "Тёмная"
        case .light: "Светлая"
        }
    }
    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .dark: "moon"
        case .light: "sun.max"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

// MARK: - Общие элементы

/// Чип-пилюля, как в kino-na-vecher.
struct Chip: View {
    @Environment(\.palette) private var p
    let title: String
    var icon: String? = nil
    var isOn: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
                Text(title).font(AppFont.body(12, isOn ? .medium : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(isOn ? p.ink : p.text)
            .background(Capsule().fill(isOn ? p.accent : .clear))
            .overlay(Capsule().stroke(isOn ? p.accent : (hover ? p.muted : p.line), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Маленький переключатель-иконка (тема).
struct IconChip: View {
    @Environment(\.palette) private var p
    let systemName: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(isOn ? p.ink : p.muted)
                .background(Capsule().fill(isOn ? p.accent : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Круглая иконка-кнопка.
struct IconButton: View {
    @Environment(\.palette) private var p
    let systemName: String
    let help: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(hover ? p.text : p.muted)
                .background(Circle().fill(hover ? p.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct ProgressTrack: View {
    @Environment(\.palette) private var p
    var value: Double
    var color: Color? = nil
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(p.line)
                Capsule().fill(color ?? p.accent)
                    .frame(width: max(height, g.size.width * min(max(value, 0), 1)))
                    .opacity(value <= 0 ? 0 : 1)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.15), value: value)
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - Режим снимка (отладка): ImageRenderer не рисует ScrollView и Menu.

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

struct Scrollable<Content: View>: View {
    @Environment(\.isSnapshot) private var snap
    var axis: Axis.Set = .vertical
    @ViewBuilder var content: Content
    var body: some View {
        if snap && axis == .horizontal {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else if snap {
            content.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView(axis, showsIndicators: axis == .vertical) { content }
        }
    }
}
