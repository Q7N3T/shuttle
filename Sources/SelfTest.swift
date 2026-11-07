#if DEBUG
import Foundation
import CryptoKit

/// Отладка: `Shuttle --selftest` прогоняет реальные операции на подключённом телефоне.
/// Всё делается во временной папке ShuttleSelfTest в корне памяти и удаляется в конце.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let code = run()
        exit(code)
    }

    private static var failures = 0

    private static func step<T>(_ name: String, _ body: () throws -> T) -> T? {
        let t0 = Date()
        do {
            let r = try body()
            print("✅ \(name)  (\(ms(t0)))")
            return r
        } catch {
            failures += 1
            print("❌ \(name): \(error.localizedDescription)")
            return nil
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { print("✅ \(name)") } else { failures += 1; print("❌ \(name) \(detail)") }
    }

    private static func ms(_ t0: Date) -> String { "\(Int(Date().timeIntervalSince(t0) * 1000)) мс" }

    private static func sha(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url) else { return "-" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func run() -> Int32 {
        let svc = MTPService.shared
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ShuttleSelfTest-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); svc.release() }

        print("— Подключение")
        guard let info = step("Подключение к телефону", { try svc.connectIfNeeded() }) else { return 1 }
        print("   \(info.name) · \(info.storageName) · свободно \(formatBytes(info.free)) из \(formatBytes(info.capacity)) · заряд \(info.battery.map { "\($0)%" } ?? "—")")
        print("   Разделов: \(info.storages.count), тип: \(info.kind == .console ? "консоль" : "телефон")")
        for st in info.storages {
            let n = (try? svc.list(storage: st.id, parent: mtpRoot).count).map(String.init) ?? "ошибка"
            print("   • \(st.name): \(n) объектов в корне, свободно \(formatBytes(st.free)) из \(formatBytes(st.capacity))")
        }
        check("Разделы видны", !info.storages.isEmpty)
        _ = step("Повторный опрос (heartbeat)") { try svc.heartbeat() }

        print("— Чтение")
        let root = step("Список корня") { try svc.list(storage: info.storageID, parent: mtpRoot) } ?? []
        print("   В корне \(root.count): \(root.prefix(8).map { $0.isFolder ? $0.name + "/" : $0.name }.joined(separator: ", "))")
        for q in QuickFolder.android where info.kind == .phone {
            let t0 = Date()
            do {
                let c = try svc.resolve(path: q.path, storage: info.storageID)
                let n = try svc.list(storage: info.storageID, parent: c.last!.id).count
                print("   ✅ \(q.title) → /\(q.path.joined(separator: "/")): \(n) объектов (\(ms(t0)))")
            } catch {
                print("   ⚠️ \(q.title): \(error.localizedDescription)")
            }
        }

        print("— Запись (папка ShuttleSelfTest)")
        // Убираем хвосты от прошлого прогона.
        for old in root where old.isFolder && old.name == "ShuttleSelfTest" { try? svc.deleteTree(old) }

        guard let folder = step("Создание папки", {
            try svc.createFolder("ShuttleSelfTest", parent: mtpRoot, storage: info.storageID)
        }) else { return 1 }

        // Тестовые файлы: маленький, с кириллицей и пробелом, и 50 МБ для скорости.
        let small = work.appendingPathComponent("hello.txt")
        try? "Привет от Shuttle \(Date())".data(using: .utf8)!.write(to: small)
        let cyr = work.appendingPathComponent("Тест файл №1.txt")
        try? Data((0..<4096).map { UInt8($0 % 251) }).write(to: cyr)
        let big = work.appendingPathComponent("big.bin")
        var bytes = [UInt8](repeating: 0, count: 50 * 1024 * 1024)
        for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8(truncatingIfNeeded: i / 4096) }
        try? Data(bytes).write(to: big)
        bytes = []

        let nested = work.appendingPathComponent("Папка с файлами")
        try? fm.createDirectory(at: nested.appendingPathComponent("внутри"), withIntermediateDirectories: true)
        try? "a".write(to: nested.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "b".write(to: nested.appendingPathComponent("внутри/b.txt"), atomically: true, encoding: .utf8)

        for f in [small, cyr] {
            _ = step("Загрузка «\(f.lastPathComponent)»") {
                try svc.upload(f, parent: folder, storage: info.storageID) { _, _ in true }
            }
        }

        var lastProgress: UInt64 = 0
        var calls = 0
        let t0 = Date()
        if step("Загрузка 50 МБ с прогрессом", {
            try svc.upload(big, parent: folder, storage: info.storageID) { s, _ in lastProgress = s; calls += 1; return true }
        }) != nil {
            let sec = Date().timeIntervalSince(t0)
            print("   скорость на телефон: \(formatBytes(UInt64(Double(50 * 1024 * 1024) / sec)))/с, колбэков прогресса: \(calls)")
            check("Прогресс ровно 100%", lastProgress == 50 * 1024 * 1024, "(\(lastProgress))")
        }

        _ = step("Загрузка папки с вложенной папкой") {
            try svc.uploadTree([nested], parent: folder, storage: info.storageID, token: CancelToken()) { _, _ in }
        }

        let listed = step("Список ShuttleSelfTest") { try svc.list(storage: info.storageID, parent: folder) } ?? []
        print("   \(listed.map { $0.isFolder ? $0.name + "/" : "\($0.name) (\($0.size) Б)" }.joined(separator: ", "))")
        let names = Set(listed.map(\.name))
        check("Все объекты на месте", names.isSuperset(of: ["hello.txt", "Тест файл №1.txt", "big.bin", "Папка с файлами"]))

        print("— Скачивание и сверка")
        let back = work.appendingPathComponent("back", isDirectory: true)
        try? fm.createDirectory(at: back, withIntermediateDirectories: true)
        for src in [small, cyr, big] {
            guard let remote = listed.first(where: { $0.name == src.lastPathComponent }) else { continue }
            let t1 = Date()
            if let url = step("Скачивание «\(src.lastPathComponent)»", {
                try svc.downloadTree(remote, into: back, token: CancelToken()) { _, _ in }
            }) {
                if src == big {
                    let sec = Date().timeIntervalSince(t1)
                    print("   скорость на Mac: \(formatBytes(UInt64(Double(50 * 1024 * 1024) / sec)))/с")
                }
                check("   SHA-256 совпадает", sha(url) == sha(src))
            }
        }
        if let dir = listed.first(where: { $0.name == "Папка с файлами" }),
           let url = step("Скачивание папки целиком", { try svc.downloadTree(dir, into: back, token: CancelToken()) { _, _ in } }) {
            let b = try? String(contentsOf: url.appendingPathComponent("внутри/b.txt"), encoding: .utf8)
            check("   Вложенный файл совпадает", b == "b")
        }
        // Повторное скачивание не перезаписывает, а добавляет « 2».
        if let remote = listed.first(where: { $0.name == "hello.txt" }),
           let url = step("Скачивание с тем же именем", { try svc.downloadTree(remote, into: back, token: CancelToken()) { _, _ in } }) {
            check("   Получилось «hello 2.txt»", url.lastPathComponent == "hello 2.txt", url.lastPathComponent)
        }

        print("— Отмена")
        if let remote = listed.first(where: { $0.name == "big.bin" }) {
            let token = CancelToken()
            do {
                _ = try svc.downloadTree(remote, into: back, token: token) { s, _ in
                    if s > 5 * 1024 * 1024 { token.cancel() }
                }
                check("Отмена скачивания", false, "(файл скачался целиком)")
            } catch let e as MTPError {
                check("Отмена скачивания", e == .cancelled, "(\(e.localizedDescription))")
                check("   Недокачанный файл удалён", !fm.fileExists(atPath: back.appendingPathComponent("big 2.bin").path))
            } catch {
                check("Отмена скачивания", false, error.localizedDescription)
            }
            _ = step("Телефон отвечает после отмены") { try svc.list(storage: info.storageID, parent: folder) }
        }

        print("— Переименование и удаление")
        if let f = listed.first(where: { $0.name == "hello.txt" }) {
            _ = step("Переименование hello.txt → привет.txt") { try svc.rename(f.id, to: "привет.txt") }
            let after = (try? svc.list(storage: info.storageID, parent: folder)) ?? []
            check("   Новое имя видно", after.contains { $0.name == "привет.txt" })
        }
        let current = (try? svc.list(storage: info.storageID, parent: mtpRoot)) ?? []
        if let f = current.first(where: { $0.id == folder }) {
            _ = step("Удаление ShuttleSelfTest целиком") { try svc.deleteTree(f) }
        }
        let rootAfter = (try? svc.list(storage: info.storageID, parent: mtpRoot)) ?? []
        check("Папка удалена с телефона", !rootAfter.contains { $0.name == "ShuttleSelfTest" })

        print("")
        print(failures == 0 ? "Итог: всё прошло" : "Итог: ошибок \(failures)")
        return failures == 0 ? 0 : 1
    }

}
#endif
