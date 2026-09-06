import Foundation

enum CrawlLargeDocument {
    /// 25,000 logical lines and exactly 1,000,000 UTF-16 units, without a trailing structural line.
    static let text: String = {
        var text = ""
        for index in 0..<25_000 {
            let prefix = index % 19 == 0 ? " \t " : "\(index) 日本語 🦊 e\u{301} thought "
            let length = index == 24_999 ? 40 : 39
            text += prefix + String(repeating: " ", count: length - prefix.utf16.count)
            if index != 24_999 { text += "\n" }
        }
        return text
    }()
}
