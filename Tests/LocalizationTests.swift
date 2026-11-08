import XCTest
@testable import Shuttle

/// Every L("…") string in the code is translated, and the format specifiers match.
final class LocalizationTests: XCTestCase {
    func keysInSources() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let re = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let f as URL in en where f.pathExtension == "swift" && f.lastPathComponent != "English.swift" {
            let s = try String(contentsOf: f, encoding: .utf8)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                keys.insert(String(s[Range(m.range(at: 1), in: s)!]).replacingOccurrences(of: #"\""#, with: "\""))
            }
        }
        return keys
    }

    func testEverythingTranslated() throws {
        let keys = try keysInSources().filter { !$0.hasPrefix("http") }
        XCTAssertGreaterThan(keys.count, 300)
        let missing = keys.filter { English.table[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "Missing translations: \(missing.sorted())")
    }

    func testFormatSpecifiersMatch() throws {
        let re = try NSRegularExpression(pattern: #"%(?:%|@|d|ld|lld|u)"#)
        func specs(_ s: String) -> [String] {
            re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
        }
        for (ru, en) in English.table {
            XCTAssertEqual(specs(ru), specs(en), "«\(ru)» → «\(en)»")
        }
    }

    func testNoUnusedTranslations() throws {
        let keys = try keysInSources()
        let unused = English.table.keys.filter { !keys.contains($0) }
        XCTAssertTrue(unused.isEmpty, "Unused translations: \(unused.sorted())")
    }
}
