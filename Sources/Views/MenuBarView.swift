import SwiftUI

/// Иконка в строке меню: устройство, место, быстрые действия.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let d = state.device {
            Text(d.name)
            if let s = state.currentStorage ?? d.storages.first, s.capacity > 0 {
                Text(L("%@ свободно из %@", formatBytes(s.free), formatBytes(s.capacity)))
            }
            if let b = d.battery { Text(L("Заряд: %d%%", b)) }
            Divider()
            if d.kind == .phone {
                Button(L("Скачать новое с камеры (%d)", state.newPhotos.count)) { state.importNewPhotos() }
                    .disabled(state.newPhotos.isEmpty)
                Button(L("Синхронизировать")) {
                    state.runSyncs(SyncStore.shared.rules(for: d.key).filter(\.enabled))
                }
                .disabled(SyncStore.shared.rules(for: d.key).isEmpty)
            } else {
                Button(L("Сохранить сейвы")) { state.backupSaves() }
                    .disabled(d.storage(where: \.isSaves) == nil)
            }
        } else if state.nintendoWithoutMTP {
            Text(L("Switch: запустите DBI → MTP"))
        } else {
            Text(L("Устройство не подключено"))
        }
        let active = state.transfers.filter { $0.state.isActive }.count
        if active > 0 {
            Divider()
            Text(L("В работе: %d", active))
        }
        Divider()
        Button(L("Открыть Shuttle")) {
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) }
            else { openWindow(id: "main") }
        }
        Button(L("История передач")) {
            NSApp.activate(ignoringOtherApps: true)
            state.showHistory = true
        }
        Divider()
        Button(L("Завершить Shuttle")) { NSApp.terminate(nil) }
    }
}

/// Значок для строки меню — маленький дроид (шаблонное изображение под тему строки меню).
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { r in
            let w = r.width, h = r.height
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ant = NSBezierPath()
            ant.lineWidth = 1.5
            ant.lineCapStyle = .round
            ant.move(to: NSPoint(x: w * 0.34, y: h * 0.38)); ant.line(to: NSPoint(x: w * 0.24, y: h * 0.14))
            ant.move(to: NSPoint(x: w * 0.66, y: h * 0.38)); ant.line(to: NSPoint(x: w * 0.76, y: h * 0.14))
            ant.stroke()
            let head = NSBezierPath(roundedRect: NSRect(x: w * 0.06, y: h * 0.36, width: w * 0.88, height: h * 0.52),
                                    xRadius: h * 0.26, yRadius: h * 0.26)
            head.fill()
            // Глаза-стрелки вырезаем.
            NSGraphicsContext.current?.compositingOperation = .clear
            let eyes = NSBezierPath()
            eyes.lineWidth = 1.6
            eyes.lineCapStyle = .round
            eyes.lineJoinStyle = .round
            let cy = h * 0.62
            eyes.move(to: NSPoint(x: w * 0.40, y: cy - h * 0.11)); eyes.line(to: NSPoint(x: w * 0.32, y: cy))
            eyes.line(to: NSPoint(x: w * 0.40, y: cy + h * 0.11))
            eyes.move(to: NSPoint(x: w * 0.60, y: cy - h * 0.11)); eyes.line(to: NSPoint(x: w * 0.68, y: cy))
            eyes.line(to: NSPoint(x: w * 0.60, y: cy + h * 0.11))
            eyes.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
