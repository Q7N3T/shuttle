import SwiftUI

struct TransferPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("Передачи")).font(AppFont.display(13))
                Text(summary).font(AppFont.body(12)).foregroundStyle(p.muted)
                Spacer()
                Button { state.showHistory = true } label: {
                    Label(L("История"), systemImage: "clock.arrow.circlepath").font(AppFont.body(12))
                }
                .buttonStyle(.plain).foregroundStyle(p.muted)
                if state.transfers.contains(where: { $0.state.isFinished }) {
                    Chip(title: L("Очистить")) { withAnimation { state.clearFinished() } }
                }
            }
            if !state.transfers.isEmpty {
                Scrollable {
                    LazyVStack(spacing: 6) {
                        ForEach(state.transfers) {
                            TransferRow(transfer: $0)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(state.transfers.count) * 40, 124))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.transfers.count)
    }

    private var summary: String {
        let active = state.transfers.filter { $0.state.isActive }.count
        let waiting = state.transfers.filter { $0.state == .waiting }.count
        if active > 0 { return L("В работе: %d", active) }
        if waiting > 0 { return L("Ждём устройство: %d", waiting) }
        return state.transfers.isEmpty ? L("Перетащите файл между панелями") : L("Всё готово")
    }
}

struct TransferRow: View {
    @ObservedObject var transfer: Transfer
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .toMac ? "arrow.left" : "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.accent)
                .frame(width: 14)
            HStack(spacing: 6) {
                if let label = transfer.label {
                    Text(label).font(AppFont.body(10, .medium)).foregroundStyle(p.ink)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(p.accent.opacity(0.85)))
                }
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 220, alignment: .leading)
            ProgressTrack(value: transfer.fraction,
                          color: transfer.state == .done ? p.ok : (transfer.state == .waiting ? p.muted : nil))
                // Shuttle the mascot runs along the bar; if the cable drops it sits down and waits
                .overlay {
                    if transfer.state == .running || transfer.state == .waiting {
                        MascotRunner(fraction: transfer.fraction, waiting: transfer.state == .waiting)
                    }
                }
            status.frame(width: 140, alignment: .trailing)
            trailing
        }
        .font(AppFont.body(12))
        .padding(.horizontal, 12).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.line, lineWidth: 1))
    }

    @ViewBuilder
    private var status: some View {
        switch transfer.state {
        case .queued:
            Text(L("В очереди")).foregroundStyle(p.muted)
        case .running:
            Text(transfer.total == 0 ? L("Готовим…") : "\(Int(transfer.fraction * 100))% · \(speed)")
                .monospacedDigit().foregroundStyle(p.muted)
        case .waiting:
            Label(L("Ждём устройство"), systemImage: "pause.circle").foregroundStyle(p.accent)
                .help(L("Связь прервалась. Подключите то же устройство — передача продолжится сама."))
        case .done:
            HStack(spacing: 6) {
                if transfer.verified {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(p.ok)
                        .help(L("Сверено: на устройстве и на Mac одинаковый размер"))
                }
                Text(formatBytes(transfer.total)).foregroundStyle(p.muted)
            }
        case .cancelled:
            Text(L("Отменено")).foregroundStyle(p.muted)
        case .failed(let m):
            Text(L("Ошибка")).foregroundStyle(p.danger).help(m)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch transfer.state {
        case .queued, .running, .waiting:
            IconButton(systemName: "xmark", help: L("Отменить")) { transfer.cancel() }
        case .done:
            if let url = transfer.resultURL {
                IconButton(systemName: "magnifyingglass", help: L("Показать в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {
                Image(systemName: "checkmark").foregroundStyle(p.ok).frame(width: 26)
            }
        case .failed:
            if transfer.restart != nil {
                IconButton(systemName: "arrow.clockwise", help: L("Повторить")) {
                    transfer.prepareRetry()
                    transfer.restart?()
                }
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
        default:
            Color.clear.frame(width: 26, height: 26)
        }
    }

    private var speed: String {
        transfer.bytesPerSecond > 0 ? "\(formatBytes(UInt64(transfer.bytesPerSecond)))/\(L("с"))" : "…"
    }
}
