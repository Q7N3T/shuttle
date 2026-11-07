import Foundation

/// Пакетное переименование по шаблону.
/// Метки: {name} — имя без расширения, {n} — номер, {date} — дата изменения, {ext} — расширение.
/// Расширение сохраняется само, если в шаблоне нет {ext}.
struct RenamePattern {
    var template: String = "{date} {name}"
    var start: Int = 1
    var digits: Int = 2

    struct Input { let name: String; let modified: Date; let isFolder: Bool }

    func apply(_ items: [Input]) -> [String] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        var used = Set<String>()
        return items.enumerated().map { i, it in
            let ns = it.name as NSString
            let ext = it.isFolder ? "" : ns.pathExtension
            let base = it.isFolder || ext.isEmpty ? it.name : ns.deletingPathExtension
            let number = String(format: "%0\(max(1, digits))d", start + i)
            let date = it.modified.timeIntervalSince1970 > 315_532_800 ? df.string(from: it.modified) : ""
            var out = template
                .replacingOccurrences(of: "{name}", with: base)
                .replacingOccurrences(of: "{n}", with: number)
                .replacingOccurrences(of: "{date}", with: date)
                .replacingOccurrences(of: "{ext}", with: ext)
            out = out.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if out.isEmpty { out = base }
            if !template.contains("{ext}"), !ext.isEmpty { out += "." + ext }
            // Одинаковые имена в одной папке — добавляем номер.
            var candidate = out
            var k = 2
            while used.contains(candidate.lowercased()) {
                let cns = out as NSString
                candidate = ext.isEmpty ? "\(out) \(k)" : "\(cns.deletingPathExtension) \(k).\(cns.pathExtension)"
                k += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}
