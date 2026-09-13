import Foundation
import SwiftUI

/// Internationalization and localization helpers for Aureways.
public enum L10n {
    /// Look up a localized string from `Bundle.main` using the given key.
    /// Returns the key itself if no translation is found.
    public static func tr(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Look up a localized format string from `Bundle.main` and format with arguments.
    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale.current, arguments: args)
    }
}

public extension String {
    /// Returns the localized string from `Bundle.main` for this key.
    var localized: String {
        Bundle.main.localizedString(forKey: self, value: nil, table: nil)
    }

    /// Returns the localized string formatted with the provided arguments.
    func localized(_ args: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: self, value: nil, table: nil)
        return String(format: format, locale: Locale.current, arguments: args)
    }
}
