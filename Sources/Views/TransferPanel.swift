import SwiftUI

struct TransferPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Передачи").font(AppFont.display(13))
                Text(summary).font(AppFont.body(12)).foregroundStyle(p.muted)
                Spacer()
                if state.transfers.contains(where: { $0.state.isFinished }) {
                    Chip(title: "Очистить") { state.clearFinished() }
                }
            }
            if !state.transfers.isEmpty {
                Scrollable {
                    LazyVStack(spacing: 8) {
                        ForEach(state.transfers) { TransferRow(transfer: $0) }
                    }
                }
                .frame(maxHeight: min(CGFloat(state.transfers.count) * 50, 160))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
    }

    private var summary: String {
        let active = state.transfers.filter { !$0.state.isFinished }.count
        if active > 0 { return "В работе: \(active)" }
        return state.transfers.isEmpty ? "Перетащите файл между панелями" : "Всё готово"
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
            Text(transfer.name).lineLimit(1).truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            ProgressTrack(value: transfer.fraction,
                          color: transfer.state == .done ? p.ok : nil)
            status.frame(width: 120, alignment: .trailing)
            trailing
        }
        .font(AppFont.body(13))
        .padding(.horizontal, 14).frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.line, lineWidth: 1))
    }

    @ViewBuilder
    private var status: some View {
        switch transfer.state {
        case .queued:
            Text("В очереди").foregroundStyle(p.muted)
        case .running:
            Text("\(Int(transfer.fraction * 100))% · \(speed)")
                .monospacedDigit().foregroundStyle(p.muted)
        case .done:
            Text(formatBytes(transfer.total)).foregroundStyle(p.muted)
        case .cancelled:
            Text("Отменено").foregroundStyle(p.muted)
        case .failed(let m):
            Text("Ошибка").foregroundStyle(p.danger).help(m)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch transfer.state {
        case .queued, .running:
            IconButton(systemName: "xmark", help: "Отменить") { transfer.cancel() }
        case .done:
            if let url = transfer.resultURL {
                IconButton(systemName: "magnifyingglass", help: "Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {
                Image(systemName: "checkmark").foregroundStyle(p.ok).frame(width: 26)
            }
        default:
            Color.clear.frame(width: 26, height: 26)
        }
    }

    private var speed: String {
        transfer.bytesPerSecond > 0 ? "\(formatBytes(UInt64(transfer.bytesPerSecond)))/с" : "…"
    }

    private var font: Font { AppFont.body(12) }
}
