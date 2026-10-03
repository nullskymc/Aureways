import XCTest
@testable import Aureways

final class LocalizationTests: XCTestCase {

    override func tearDown() {
        L10n.languageCode = L10n.systemLanguage
        super.tearDown()
    }

    private func findXCStringsURL() -> URL? {
        let fromFilePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Aureways")
            .appendingPathComponent("Localizable.xcstrings")
            .standardized
        if FileManager.default.fileExists(atPath: fromFilePath.path) {
            return fromFilePath
        }

        let fromCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Aureways")
            .appendingPathComponent("Localizable.xcstrings")
            .standardized
        if FileManager.default.fileExists(atPath: fromCwd.path) {
            return fromCwd
        }
        return nil
    }

    func testLocalizationHelperExtension() {
        // String.localized fallback when key is not found
        let nonExistent = "NonExistentKey_12345"
        XCTAssertEqual(nonExistent.localized, nonExistent)

        // L10n.tr fallback
        XCTAssertEqual(L10n.tr(nonExistent), nonExistent)
    }

    func testLanguageOverrideSelectsCatalog() {
        let previous = L10n.languageCode
        defer { L10n.languageCode = previous }

        guard Bundle.main.path(forResource: "en", ofType: "lproj") != nil else {
            // Test host without compiled catalogs still has to accept the setter.
            L10n.languageCode = "en"
            XCTAssertEqual(L10n.languageCode, "en")
            return
        }

        L10n.languageCode = "en"
        XCTAssertEqual(L10n.tr("新对话"), "New Chat")
        L10n.languageCode = "zh-Hans"
        XCTAssertEqual(L10n.tr("新对话"), "新对话")
        L10n.languageCode = "not-a-locale"
        XCTAssertEqual(L10n.languageCode, L10n.systemLanguage)
    }

    func testLocalizableXCStringsIntegrity() throws {
        guard let fileURL = findXCStringsURL() else {
            XCTFail("Localizable.xcstrings not found")
            return
        }

        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["version"] as? String, "1.0")
        XCTAssertEqual(json?["sourceLanguage"] as? String, "zh-Hans")

        let strings = json?["strings"] as? [String: [String: Any]]
        XCTAssertNotNil(strings)
        guard let strings else { return }

        // The web shell carries its own strings; the catalog only holds what
        // native code still shows (menus, panels, notifications, agent hints).
        XCTAssertGreaterThan(strings.count, 30, "Native strings went missing")

        // Validate essential UI keys are present and translated
        let keyChecks = [
            "新对话": "New Chat",
            "取消": "Cancel",
            "打开": "Open",
            "读取文件": "Read File",
            "编辑文件": "Edit File",
            "执行命令": "Execute Command",
            "搜索": "Search",
        ]

        for (key, expectedEn) in keyChecks {
            guard let entry = strings[key] else {
                XCTFail("Missing essential key: \(key)")
                continue
            }
            let locs = entry["localizations"] as? [String: Any]
            let enUnit = (locs?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let enValue = enUnit?["value"] as? String
            XCTAssertEqual(enValue, expectedEn, "Translation mismatch for key \(key)")
        }

        // Verify all non-empty entries have valid English translations
        var missingEnCount = 0
        var emptyEnCount = 0
        var chineseInEnCount = 0

        let chineseRegex = try NSRegularExpression(pattern: "[\\u4e00-\\u9fff]")

        for (key, entry) in strings {
            if key.isEmpty { continue }
            let locs = entry["localizations"] as? [String: Any]
            guard let en = locs?["en"] as? [String: Any],
                  let enUnit = en["stringUnit"] as? [String: Any],
                  let enVal = enUnit["value"] as? String else {
                missingEnCount += 1
                continue
            }

            if enVal.isEmpty {
                emptyEnCount += 1
            }

            let matches = chineseRegex.matches(in: enVal, range: NSRange(enVal.startIndex..., in: enVal))
            if !matches.isEmpty {
                chineseInEnCount += 1
            }
        }

        XCTAssertEqual(missingEnCount, 0, "All entries must have English localizations")
        XCTAssertEqual(emptyEnCount, 0, "No English localization value should be empty")
        XCTAssertEqual(chineseInEnCount, 0, "No English localization value should contain Chinese characters")
    }

    /// Every catalog key must still be used as a literal somewhere in the app
    /// sources (keys are always looked up as `"…".localized` / `L10n.tr("…")`),
    /// so dead strings don't pile up again.
    func testNoUnusedCatalogKeys() throws {
        guard let fileURL = findXCStringsURL() else {
            XCTFail("Localizable.xcstrings not found")
            return
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let strings = json?["strings"] as? [String: Any] ?? [:]
        let sourceDir = fileURL.deletingLastPathComponent()
        var source = ""
        let enumerator = FileManager.default.enumerator(at: sourceDir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) {
                source += text
            }
        }
        guard !source.isEmpty else { return }
        // …and every literal lookup must have a catalog entry (else English
        // users see the Chinese source string).
        let lookup = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\.localized|L10n\.tr\("((?:[^"\\]|\\.)*)""#)
        let range = NSRange(source.startIndex..., in: source)
        for match in lookup.matches(in: source, range: range) {
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let keyRange = Range(match.range(at: group), in: source) else { continue }
            let key = String(source[keyRange]).replacingOccurrences(of: "\\n", with: "\n")
            XCTAssertNotNil(strings[key], "Missing catalog entry for: \(key)")
        }
        for key in strings.keys where !key.isEmpty {
            let literal = "\"" + key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
            XCTAssertTrue(source.contains(literal), "Unused catalog key: \(key)")
        }
    }

    func testFormatSpecifiersConsistency() throws {
        guard let fileURL = findXCStringsURL() else {
            XCTFail("Localizable.xcstrings not found")
            return
        }

        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let strings = json?["strings"] as? [String: [String: Any]] else {
            XCTFail("Missing strings in xcstrings")
            return
        }

        // Ensure key format tokens (e.g. %lld, %@) are not lost in translations
        for (key, entry) in strings {
            guard let locs = entry["localizations"] as? [String: Any],
                  let enUnit = (locs["en"] as? [String: Any])?["stringUnit"] as? [String: Any],
                  let enVal = enUnit["value"] as? String else {
                continue
            }

            // Check %lld
            if key.contains("%lld") {
                XCTAssertTrue(enVal.contains("%lld") || enVal.contains("%1$lld") || enVal.contains("%2$lld") || enVal.contains("%3$lld"),
                              "Expected %lld in translation for key '\(key)', got '\(enVal)'")
            }

            // Check %@
            if key.contains("%@") {
                XCTAssertTrue(enVal.contains("%@") || enVal.contains("%1$@") || enVal.contains("%2$@"),
                              "Expected %@ in translation for key '\(key)', got '\(enVal)'")
            }
        }
    }
}
