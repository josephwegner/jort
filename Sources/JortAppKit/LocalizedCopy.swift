import Foundation

private final class LocalizationBundleMarker {}

/// Stable keys live in Resources/en.lproj/Localizable.strings. The explicit
/// English fallback also works in command-line test hosts without resources.
enum LocalizedCopy {
  static func text(_ key: String, fallback: String) -> String {
    Bundle(for: LocalizationBundleMarker.self).localizedString(
      forKey: key, value: fallback, table: nil)
  }
  static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
    String(format: text(key, fallback: fallback), locale: Locale.current, arguments: arguments)
  }

}
