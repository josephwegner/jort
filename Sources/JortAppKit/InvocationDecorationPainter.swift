import AppKit

/// Paths are built once and never mutated after this snapshot is committed.
@MainActor struct InvocationPaintSnapshot {
  struct Shape {
    let invocationID: UUID
    let path: NSBezierPath
    let color: NSColor
  }
  let shapes: [Shape]
  func contains(_ point: NSPoint, pending: Bool) -> Bool {
    shapes.contains { shape in
      let path = shape.path, color = shape.color
      return (color == ToolPresentationColors.pending) == pending && path.contains(point)
    }
  }
  func draw(_ rect: NSRect) {
    for shape in shapes where shape.path.elementCount > 0 && shape.path.bounds.intersects(rect) {
      let path = shape.path, color = shape.color
      ToolPresentationColors.canvas.blended(withFraction: 0.16, of: color)!.setFill()
      path.fill()
      color.withAlphaComponent(0.65).setStroke()
      path.stroke()
    }
  }
  func removing(_ invocationIDs: Set<UUID>) -> Self {
    .init(shapes: shapes.filter { !invocationIDs.contains($0.invocationID) })
  }
}
