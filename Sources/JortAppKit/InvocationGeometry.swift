import AppKit
import JortDocument

@MainActor enum InvocationGeometry {
  /// Trace the union's boundary on a coordinate grid, omitting every shared edge.
  static func union(_ rectangles: [NSRect]) -> NSBezierPath {
    let rects = rectangles.filter { $0.width > 0 && $0.height > 0 }
    let result = NSBezierPath()
    result.lineWidth = 1
    guard !rects.isEmpty else { return result }
    let xs = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
    let ys = Array(Set(rects.flatMap { [$0.minY, $0.maxY] })).sorted()
    struct Point: Hashable {
      let x: Int
      let y: Int
    }
    var occupied = Set<Point>()
    for x in 0..<max(0, xs.count - 1) {
      for y in 0..<max(0, ys.count - 1) {
        let center = NSPoint(x: (xs[x] + xs[x + 1]) / 2, y: (ys[y] + ys[y + 1]) / 2)
        if rects.contains(where: { $0.contains(center) }) { occupied.insert(Point(x: x, y: y)) }
      }
    }
    var edges: [Point: Point] = [:]
    for p in occupied {
      if !occupied.contains(Point(x: p.x, y: p.y - 1)) { edges[p] = Point(x: p.x + 1, y: p.y) }
      if !occupied.contains(Point(x: p.x + 1, y: p.y)) {
        edges[Point(x: p.x + 1, y: p.y)] = Point(x: p.x + 1, y: p.y + 1)
      }
      if !occupied.contains(Point(x: p.x, y: p.y + 1)) {
        edges[Point(x: p.x + 1, y: p.y + 1)] = Point(x: p.x, y: p.y + 1)
      }
      if !occupied.contains(Point(x: p.x - 1, y: p.y)) { edges[Point(x: p.x, y: p.y + 1)] = p }
    }
    while let start = edges.keys.first {
      var points: [NSPoint] = []
      var current = start
      while let next = edges.removeValue(forKey: current) {
        points.append(NSPoint(x: xs[current.x], y: ys[current.y]))
        current = next
        if current == start { break }
      }
      guard points.count >= 3 else { continue }
      // Remove collinear grid vertices before rounding only boundary corners.
      points = points.indices.compactMap { index in
        let p = points[(index + points.count - 1) % points.count], c = points[index],
          n = points[(index + 1) % points.count]
        return p.x == c.x && c.x == n.x || p.y == c.y && c.y == n.y ? nil : c
      }
      guard points.count >= 3 else { continue }
      for index in points.indices {
        let p = points[(index + points.count - 1) % points.count], c = points[index],
          n = points[(index + 1) % points.count]
        let before = hypot(c.x - p.x, c.y - p.y), after = hypot(n.x - c.x, n.y - c.y)
        let radius = min(4, min(before, after) / 2)
        let a = NSPoint(
          x: c.x + (p.x - c.x) * radius / before, y: c.y + (p.y - c.y) * radius / before)
        let b = NSPoint(
          x: c.x + (n.x - c.x) * radius / after, y: c.y + (n.y - c.y) * radius / after)
        if index == 0 { result.move(to: a) } else { result.line(to: a) }
        result.curve(to: b, controlPoint1: c, controlPoint2: c)
      }
      result.close()
    }
    return result
  }
  struct Input {
    let rects: [NSRange: [NSRect]]
    let glyphs: [Int: NSRect]
    let warning: String?
  }
  struct Prepared {
    let anchor: NSRect
    let controlFrame: NSRect
    let sourceEndsLine: Bool
    let inlineActions: Bool
    let shapes: [(NSBezierPath, NSColor)]
  }
  /// Pure after bounded native capture: no views, text storage, or layout manager.
  static func prepare(
    invocation: ToolInvocation, snapshot: DocumentSnapshot,
    token: NSRange, scope: NSRange, output: NSRange?, input: Input
  ) -> Prepared? {
    var shapes: [(NSBezierPath, NSColor)] = []
    func rects(_ range: NSRange) -> [NSRect] { input.rects[range] ?? [] }
    let leading = output.map { leadingActions($0, text: snapshot.text) } ?? false
    let indented = output.map { leadingIndent($0, text: snapshot.text) } ?? false
    let emptyAtLineStart =
      output.map { $0.length == 0 && startsLine($0, text: snapshot.text) } ?? false
    let sourceEndsLine = endsLine(
      NSMaxRange(invocation.inputMode == "contextual" ? token : scope), text: snapshot.text)
    let outputEndsLine = output.map { endsLine(NSMaxRange($0), text: snapshot.text) } ?? false
    let inlineActions =
      !(invocation.inputMode.hasPrefix("ephemeral") && invocation.phase == .inputting)
    var paintedScope = scope
    // The newline belongs to the range, but the insertion position on
    // the following line does not. Do not paint that exclusive end.
    if invocation.inputMode == "contextual", paintedScope.length > 0,
      (snapshot.text as NSString).character(at: NSMaxRange(paintedScope) - 1) == 10
    {
      paintedScope.length -= 1
    }
    var sourceFrames = rects(paintedScope)
    if invocation.inputMode == "contained", invocation.phase == .inputting,
      startsLine(NSRange(location: NSMaxRange(scope), length: 0), text: snapshot.text),
      let emptyLine = rects(NSRange(location: NSMaxRange(scope), length: 0)).first,
      !sourceFrames.contains(where: { abs($0.minY - emptyLine.minY) < 2 })
    {
      sourceFrames.append(emptyLine)
    }
    var sourceRects = connected(sourceFrames)
    if output == nil, invocation.inputMode == "contextual", let tokenFrame = rects(token).last {
      sourceRects.append(
        NSRect(
          x: tokenFrame.maxX - (sourceEndsLine ? 3 : 27), y: tokenFrame.minY,
          width: sourceEndsLine ? 63 : 54, height: tokenFrame.height))
    }
    if output == nil, invocation.inputMode != "contextual", inlineActions, !sourceRects.isEmpty {
      sourceRects[sourceRects.count - 1].size.width +=
        sourceEndsLine
        ? (invocation.phase == .inputting ? 48 : 60) : (invocation.phase == .inputting ? 15 : 27)
    }
    if let output, !sourceRects.isEmpty, invocation.inputMode != "contextual" {
      sourceRects[sourceRects.count - 1].size.width -=
        output.length == 0 && !emptyAtLineStart ? 42 : leading && !indented ? 30 : 3
    }
    sourceRects = clippedBeforeFollowingGlyph(
      sourceRects, end: NSMaxRange(scope), text: snapshot.text, glyphs: input.glyphs)
    let warning = input.warning
    let color: NSColor =
      invocation.phase == .error ? .systemRed : warning == nil ? .systemTeal : .systemOrange
    shapes.append((union(sourceRects), color))
    let outputRects: [NSRect]
    if let output {
      var frames = connected(rects(output))
      if output.length == 0, let anchor = frames.first {
        let offset: CGFloat =
          emptyAtLineStart ? (output.location < snapshot.text.utf16.count ? 78 : 0) : 36
        frames = [
          NSRect(x: anchor.minX - offset, y: anchor.minY, width: 78, height: anchor.height)
        ]
      } else if !frames.isEmpty {
        frames[0].origin.x += 3
        frames[0].size.width -= 3
        if leading {
          let reserve: CGFloat = indented ? 54 : 27
          frames[0].origin.x -= reserve
          frames[0].size.width += reserve
        }
        // Standard segments include half the trailing kern. Complete
        // the action reservation, leaving clearance before the next glyph.
        else {
          frames[frames.count - 1].size.width += outputEndsLine ? 54 : 21
        }
      }
      if let a = sourceRects.last, let b = frames.first, b.minY > a.minY {
        let seam = NSRect(
          x: min(a.minX, b.minX), y: a.maxY - 2,
          width: max(a.maxX, b.maxX) - min(a.minX, b.minX), height: max(4, b.minY - a.maxY + 4))
        frames.insert(seam, at: 0)
      }
      frames = clippedBeforeFollowingGlyph(
        frames, end: NSMaxRange(output), text: snapshot.text, glyphs: input.glyphs)
      outputRects = frames
      shapes.append((union(frames), ToolPresentationColors.pending))
    } else {
      outputRects = []
    }
    var contextControl =
      invocation.inputMode == "contextual" && output == nil ? rects(token).last : nil
    contextControl?.size.width += sourceEndsLine ? 60 : 27
    let leadingAnchor =
      leading ? rects(NSRange(location: output!.location, length: 0)).first : nil
    guard let anchor = (leadingAnchor ?? outputRects.last ?? contextControl ?? sourceRects.last)
    else { return nil }
    let controlFrame = NSRect(
      x: leading ? anchor.minX - (indented ? 48 : 21) : anchor.maxX - 50, y: anchor.minY,
      width: 50, height: max(24, anchor.height))

    return Prepared(
      anchor: anchor, controlFrame: controlFrame,
      sourceEndsLine: sourceEndsLine, inlineActions: inlineActions, shapes: shapes)
  }
  private static func leadingActions(_ output: NSRange, text: String) -> Bool {
    // Long results keep their actions at the source/output seam rather than
    // requiring a scroll to the end. Short inline results retain trailing actions.
    output.length > 40 || (text as NSString).substring(with: output).contains("\n")
  }
  private static func leadingIndent(_ output: NSRange, text: String) -> Bool {
    output.length > 0 && leadingActions(output, text: text) && startsLine(output, text: text)
  }
  private static func startsLine(_ output: NSRange, text: String) -> Bool {
    output.location > 0
      && [10, 13, 0x85, 0x2028, 0x2029].contains(
        (text as NSString).character(at: output.location - 1))
  }
  private static func endsLine(_ offset: Int, text: String) -> Bool {
    let text = text as NSString
    return offset == text.length
      || offset < text.length
        && [10, 13, 0x85, 0x2028, 0x2029].contains(text.character(at: offset))
  }
  private static func connected(_ frames: [NSRect]) -> [NSRect] {
    guard frames.count > 1 else { return frames }
    var result: [NSRect] = []
    for (index, frame) in frames.enumerated() {
      if index > 0 {
        let previous = frames[index - 1]
        if frame.minY > previous.minY {
          result.append(
            NSRect(
              x: min(previous.minX, frame.minX), y: previous.maxY - 1,
              width: max(previous.maxX, frame.maxX) - min(previous.minX, frame.minX),
              height: max(2, frame.minY - previous.maxY + 2)))
        }
      }
      result.append(frame)
    }
    return result
  }
  private static func clippedBeforeFollowingGlyph(
    _ frames: [NSRect], end: Int, text: String, glyphs: [Int: NSRect]
  ) -> [NSRect] {
    guard end < text.utf16.count,
      ![10, 13, 0x85, 0x2028, 0x2029].contains((text as NSString).character(at: end)),
      let next = glyphs[end]
    else { return frames }
    // Decorations may pad into whitespace inside their range, but neither
    // their fill nor their 1pt stroke may enter the next character's cell.
    return frames.compactMap { frame in
      guard frame.maxY > next.minY + 1, frame.minY < next.maxY - 1 else { return frame }
      var clipped = frame
      clipped.size.width = min(frame.maxX, next.minX - 1) - frame.minX
      return clipped.width > 0 ? clipped : nil
    }
  }

}
