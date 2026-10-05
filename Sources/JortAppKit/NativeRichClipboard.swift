import AppKit
import JortToolContracts

/// A small Markdown renderer. All source text is escaped, and no HTML importer,
/// image loader, or network API participates in clipboard preparation.
@MainActor enum NativeRichClipboard {
  struct Representations {
    let plainText: String
    let rtf: Data
    let html: Data
  }

  static func representations(_ markdown: String) throws -> Representations {
    guard markdown.utf8.count <= 1_048_576 else {
      throw ToolFailure(.outputLimit, message: "Rich copy exceeds the input limit.")
    }
    let attributed = NSMutableAttributedString(string: "")
    var html = "<html><head><meta charset=\"utf-8\"></head><body>"
    var fenced = false
    var fenceMarker: Character = "`"
    var fenceLength = 0
    var skipUnderline = false
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    for (index, rawLine) in lines.enumerated() {
      if skipUnderline {
        skipUnderline = false
        continue
      }
      let indentation = rawLine.prefix { $0 == " " }.count
      let block = String(rawLine.dropFirst(indentation))
      let indentedCode = indentation >= 4 || rawLine.hasPrefix("\t")
      if indentation <= 3, let marker = block.first, marker == "`" || marker == "~" {
        let length = block.prefix { $0 == marker }.count
        let tail = block.dropFirst(length)
        if fenced, marker == fenceMarker, length >= fenceLength,
          tail.allSatisfy({ $0 == " " || $0 == "\t" })
        {
          fenced = false
          html += "</code></pre>"
          continue
        } else if !fenced, length >= 3, marker != "`" || !tail.contains("`") {
          fenced = true
          fenceMarker = marker
          fenceLength = length
          html += "<pre><code>"
          continue
        }
      }
      var line = rawLine
      var tag = "p"
      var font = NSFont.systemFont(ofSize: 13)
      var prefix = ""
      if fenced || indentedCode {
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        if indentedCode && !fenced { tag = "pre" }
      } else {
        let hashes = block.prefix { $0 == "#" }.count
        let afterHashes = block.dropFirst(hashes)
        if (1...6).contains(hashes),
          afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t"
        {
          line = String(afterHashes).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
          tag = "h\(hashes)"
          font = .boldSystemFont(ofSize: CGFloat(23 - hashes))
        } else if !block.isEmpty, index + 1 < lines.count,
          let level = setextLevel(lines[index + 1]), !block.hasPrefix(">"),
          !["- ", "* ", "+ "].contains(where: { block.hasPrefix($0) })
        {
          line = block
          tag = "h\(level)"
          font = .boldSystemFont(ofSize: CGFloat(23 - level))
          skipUnderline = true
        } else if block.hasPrefix("> ") {
          line = String(block.dropFirst(2))
          tag = "blockquote"
        } else if ["- ", "* ", "+ "].contains(where: { block.hasPrefix($0) }) {
          line = String(block.dropFirst(2))
          prefix = "• "
        }
      }
      if !prefix.isEmpty {
        attributed.append(NSAttributedString(string: prefix, attributes: [.font: font]))
      }
      if fenced {
        attributed.append(NSAttributedString(string: line, attributes: [.font: font]))
        html += escape(line) + "\n"
      } else if indentedCode {
        attributed.append(NSAttributedString(string: line, attributes: [.font: font]))
        html += "<pre><code>\(escape(line))</code></pre>"
      } else {
        let rendered = inline(line, font: font)
        attributed.append(rendered.text)
        html += "<\(tag)>\(escape(prefix))\(rendered.html)</\(tag)>"
      }
      if index < lines.count - 1 {
        attributed.append(NSAttributedString(string: "\n", attributes: [.font: font]))
      }
      guard html.utf8.count <= 8_388_608, attributed.length <= 2_097_152 else {
        throw ToolFailure(.outputLimit, message: "Rich copy exceeds the representation limit.")
      }
    }
    if fenced { html += "</code></pre>" }
    html += "</body></html>"
    let rtf = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    guard rtf.count <= 8_388_608 else {
      throw ToolFailure(.outputLimit, message: "Rich copy exceeds the representation limit.")
    }
    return .init(plainText: attributed.string, rtf: rtf, html: Data(html.utf8))
  }

  /// This bounded renderer supports single-line Setext headings. Multiline
  /// paragraph/container constructs remain readable rather than being inferred.
  private static func setextLevel(_ line: String) -> Int? {
    let indentation = line.prefix { $0 == " " }.count
    guard indentation <= 3 else { return nil }
    let underline = line.dropFirst(indentation)
      .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    guard let marker = underline.first, marker == "=" || marker == "-",
      underline.allSatisfy({ $0 == marker })
    else { return nil }
    return marker == "=" ? 1 : 2
  }

  private static func inline(_ source: String, font: NSFont) -> (
    text: NSAttributedString, html: String
  ) {
    // Unsupported/nested constructs remain readable literal text. Each match is
    // processed once, so markup expansion cannot recurse or execute source HTML.
    let pattern =
      #"`([^`\n]+)`|\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\n]+)\*|_([^_\n]+)_|!?\[([^\]\n]*)\]\(([^)\s]+)\)"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let string = source as NSString
    let result = NSMutableAttributedString(string: "")
    var html = "", cursor = 0
    for match in regex.matches(in: source, range: NSRange(location: 0, length: string.length)) {
      let before = string.substring(
        with: NSRange(location: cursor, length: match.range.location - cursor))
      result.append(NSAttributedString(string: before, attributes: [.font: font]))
      html += escape(before)
      var attributes: [NSAttributedString.Key: Any] = [.font: font]
      var text = "", tag = "span", link: URL?
      for group in 1...6 where match.range(at: group).location != NSNotFound {
        text = string.substring(with: match.range(at: group))
        switch group {
        case 1:
          tag = "code"
          attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        case 2, 3:
          tag = "strong"
          attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        case 4, 5:
          tag = "em"
          attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        default:
          let destination = string.substring(with: match.range(at: 7))
          let isImage = string.substring(with: match.range).hasPrefix("!")
          if !isImage, let url = URL(string: destination),
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
          {
            link = url
            attributes[.link] = url
          }
        }
      }
      result.append(NSAttributedString(string: text, attributes: attributes))
      if let link {
        html += "<a href=\"\(escape(link.absoluteString))\">\(escape(text))</a>"
      } else {
        html += "<\(tag)>\(escape(text))</\(tag)>"
      }
      cursor = NSMaxRange(match.range)
    }
    let tail = string.substring(from: cursor)
    result.append(NSAttributedString(string: tail, attributes: [.font: font]))
    html += escape(tail)
    return (result, html)
  }

  private static func escape(_ source: String) -> String {
    source.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}
