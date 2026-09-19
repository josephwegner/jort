import AppKit

public enum ApplicationTheme {
  /// Called before any app-owned window; secondary surfaces inherit normally.
  @MainActor public static func install(on application: NSApplication = .shared) {
    application.appearance = NSAppearance(named: .darkAqua)
  }
}
