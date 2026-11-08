import SwiftUI

/// "Free up space on the phone": finds photos and videos that have an exact copy on the Mac,
/// verifies their contents (SHA-256 over ADB or samples over MTP) and deletes only those from the phone.
@MainActor
final class PhoneCleanup: ObservableObject {
    enum Phase: Equatable {
        case scanning(String)
        case checking(Int, Int)
        case ready
        case deleting(Int, Int)
        case done(Int, UInt64)
        case failed(String)
    }

    struct Match: Identifiable {
        let item: RemoteItem
        let local: URL
        var id: UInt32 { item.id }
    }

    @Published private(set) var phase: Phase = .scanning("")
    @Published private(set) var safe: [Match] = []
    @Published private(set) var notOnMac = 0
    @Published private(set) var differ = 0
    private let token = CancelToken()

    /// Where shots live on the phone.
    static let folders: [[String]] = [["DCIM", "Camera"], ["DCIM", "Screenshots"], ["Pictures", "Screenshots"]]

    var safeBytes: UInt64 { safe.reduce(0) { $0 + $1.item.size } }

    func cancel() { token.cancel() }

    func start(_ state: AppState) {
        guard let st = state.currentStorage ?? state.device?.storages.first else {
            phase = .failed(L("Устройство не подключено")); return
        }
        let svc = state.svc
        let roots = [state.photosDestination, state.macURL]
        let token = token
        Task {
            do {
                // 1. What's on the phone
                phase = .scanning(L("Читаем папки телефона…"))
                let remote: [RemoteItem] = try await svc.run { svc in
                    var out: [RemoteItem] = []
                    for path in Self.folders {
                        if token.isCancelled { throw MTPError.cancelled }
                        guard let folder = try? svc.resolve(path: path, storage: st.id).last else { continue }
                        out += try svc.walk(storage: st.id, root: folder.id, token: token, maxDepth: 2).map(\.item)
                    }
                    return out
                }
                // 2. What's on the Mac: name and size → file
                phase = .scanning(L("Ищем копии на Mac…"))
                let local = await Task.detached(priority: .userInitiated) { Self.localFiles(roots) }.value
                var candidates: [Match] = []
                var missing = 0
                for r in remote where !r.isFolder && r.size > 0 {
                    if let url = local[ImportLedger.key(r.name, r.size)] { candidates.append(Match(item: r, local: url)) }
                    else { missing += 1 }
                }
                notOnMac = missing
                // 3. Content verification — one file at a time, with progress
                var ok: [Match] = []
                var bad = 0
                for (i, m) in candidates.enumerated() {
                    if token.isCancelled { return }
                    phase = .checking(i, candidates.count)
                    let same = try await svc.run { $0.compare(m.item, with: m.local) }
                    if same == .identical { ok.append(m) } else { bad += 1 }
                }
                safe = ok
                differ = bad
                phase = .ready
            } catch {
                if (error as? MTPError) != .cancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func delete(_ state: AppState) {
        let items = safe.map(\.item)
        let bytes = safeBytes
        let svc = state.svc
        Task {
            var deleted = 0
            for (i, item) in items.enumerated() {
                phase = .deleting(i, items.count)
                do { try await svc.run { try $0.delete(item.id) }; deleted += 1 }
                catch { phase = .failed(error.localizedDescription); break }
            }
            if case .failed = phase {} else { phase = .done(deleted, bytes) }
            state.cache = [:]
            await state.loadAndroid(force: true)
            await state.refreshDevice()
            if deleted > 0 { state.toast(L("Освобождено: %@", formatBytes(bytes))) }
        }
    }

    /// Files in the photos folder (with all subfolders) and in the current Mac folder.
    nonisolated static func localFiles(_ roots: [URL]) -> [String: URL] {
        var out: [String: URL] = [:]
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true else { continue }
                out[ImportLedger.key(u.lastPathComponent, UInt64(v?.fileSize ?? 0))] = u
            }
        }
        return out
    }
}

struct CleanupSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PhoneCleanup()
    @State private var confirm = false

    var body: some View {
        SheetShell(icon: "externaldrive.badge.minus", title: L("Освободить место на телефоне"), subtitle: subtitle) {
            Text(L("Shuttle найдёт фото, видео и скриншоты, у которых на Mac есть точная копия, и сверит их содержимое. Удалит с телефона только сверенные — остальное не тронет."))
                .font(AppFont.body(12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            switch model.phase {
            case .scanning, .checking, .deleting:
                ProgressTrack(value: progress, height: 6)
            case .ready, .done:
                VStack(alignment: .leading, spacing: 6) {
                    row("checkmark.seal.fill", p.ok, L("Точные копии на Mac: %d · %@", model.safe.count, formatBytes(model.safeBytes)))
                    row("questionmark.circle", p.muted, L("Нет на Mac: %d — не трогаем", model.notOnMac))
                    if model.differ > 0 {
                        row("exclamationmark.triangle", p.accent, L("Отличаются или не удалось сверить: %d — не трогаем", model.differ))
                    }
                }
                if case .ready = model.phase, !model.safe.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.safe) { m in
                                HStack {
                                    Image(systemName: "checkmark.seal").foregroundStyle(p.ok)
                                    Text(m.item.name).lineLimit(1)
                                    Spacer()
                                    Text(formatBytes(m.item.size)).foregroundStyle(p.muted)
                                }
                                .font(AppFont.body(12)).padding(.horizontal, 10).frame(height: 24)
                                .help(m.local.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            }
                        }
                    }
                    .frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
                }
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle").font(AppFont.body(12)).foregroundStyle(p.danger)
            }
        } buttons: {
            Spacer()
            Chip(title: L("Закрыть")) { model.cancel(); dismiss() }
            if case .ready = model.phase, !model.safe.isEmpty {
                AccentButton(title: L("Удалить с телефона: %d", model.safe.count)) { confirm = true }
            }
        }
        .onAppear { model.start(state) }
        .confirmationDialog(L("Удалить %d файлов с телефона?", model.safe.count), isPresented: $confirm) {
            Button(L("Удалить"), role: .destructive) { model.delete(state) }
        } message: {
            Text(L("Каждый из них сверен с копией на Mac. Удаление с телефона без корзины."))
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .scanning(let s): s
        case .checking(let i, let n): L("Сверяем: %d из %d", i + 1, n)
        case .ready: model.safe.isEmpty ? L("Удалять нечего") : L("Можно освободить %@", formatBytes(model.safeBytes))
        case .deleting(let i, let n): L("Удаляем: %d из %d", i + 1, n)
        case .done(let n, let b): L("Удалено: %d · освобождено %@", n, formatBytes(b))
        case .failed: L("Не получилось")
        }
    }

    private var progress: Double {
        switch model.phase {
        case .checking(let i, let n), .deleting(let i, let n): n == 0 ? 0 : Double(i) / Double(n)
        default: 0.05
        }
    }

    private func row(_ icon: String, _ color: Color, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .font(AppFont.body(12))
    }
}
