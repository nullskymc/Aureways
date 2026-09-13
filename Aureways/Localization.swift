import Foundation
import SwiftUI

/// Internationalization and localization helpers for Aureways.
public enum L10n {
    static let languageDefaultsKey = "appLanguage"
    static let systemLanguage = "system"
    static let supportedLanguages = ["system", "zh-Hans", "en"]

    /// `system` follows macOS; otherwise an explicit catalog (`zh-Hans` / `en`).
    public static var languageCode: String {
        get {
            let stored = UserDefaults.standard.string(forKey: languageDefaultsKey) ?? systemLanguage
            return supportedLanguages.contains(stored) ? stored : systemLanguage
        }
        set {
            let code = supportedLanguages.contains(newValue) ? newValue : systemLanguage
            UserDefaults.standard.set(code, forKey: languageDefaultsKey)
        }
    }

    public static var locale: Locale {
        switch languageCode {
        case "en": return Locale(identifier: "en")
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        default: return .autoupdatingCurrent
        }
    }

    public static var bundle: Bundle {
        switch languageCode {
        case "en", "zh-Hans":
            if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
            return .main
        default:
            return .main
        }
    }

    /// Look up a localized string using the selected language catalog.
    /// Returns the key itself if no translation is found.
    public static func tr(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Look up a localized format string and format with arguments.
    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: locale, arguments: args)
    }
}

public extension String {
    /// Returns the localized string for this key in the selected language.
    var localized: String {
        L10n.tr(self)
    }

    /// Returns the localized string formatted with the provided arguments.
    func localized(_ args: CVarArg...) -> String {
        let format = L10n.bundle.localizedString(forKey: self, value: nil, table: nil)
        return String(format: format, locale: L10n.locale, arguments: args)
    }
}
