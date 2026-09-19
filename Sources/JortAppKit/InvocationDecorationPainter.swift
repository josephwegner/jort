import AppKit

/// Paths are built once and never mutated after this snapshot is committed.
@MainActor struct InvocationPaintSnapshot {
  let shapes: [(NSBezierPath, NSColor)]
  func contains(_ point: NSPoint, pending: Bool) -> Bool {
    shapes.contains { path, color in
      (color == ToolPresentationColors.pending) == pending && path.contains(point)
    }
  }
  func draw(_ rect: NSRect) {
    for (path, color) in shapes where path.elementCount > 0 && path.bounds.intersects(rect) {
      ToolPresentationColors.canvas.blended(withFraction: 0.16, of: color)!.setFill()
      path.fill()
      color.withAlphaComponent(0.65).setStroke()
      path.stroke()
    }
  }
}
