import XCTest
@testable import Aureways

final class LocalizationTests: XCTestCase {

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
        XCTAssertEqual(L10n.tr("设置"), "Settings")
        L10n.languageCode = "zh-Hans"
        XCTAssertEqual(L10n.tr("设置"), "设置")
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

        XCTAssertGreaterThan(strings.count, 200, "Should have more than 200 localized strings")

        // Validate essential UI keys are present and translated
        let keyChecks = [
            "新对话": "New Chat",
            "重试": "Retry",
            "设置": "Settings",
            "工作区": "Workspaces",
            "取消": "Cancel",
            "确认": "Confirm",
            "批准": "Approve",
            "放弃": "Discard",
            "正在思考": "Thinking",
            "读取文件": "Read File",
            "编辑文件": "Edit File",
            "执行命令": "Execute Command",
            "搜索": "Search",
            "终端": "Terminal",
            "检查器": "Inspector"
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
