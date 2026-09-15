import Foundation

public enum ToolInputNormalization {
  /// Command acceptance may add one ASCII space. Every remaining scalar is input.
  public static func submitted(_ content: String) -> String {
    content.unicodeScalars.first?.value == 0x20
      ? String(content.unicodeScalars.dropFirst()) : content
  }
}
