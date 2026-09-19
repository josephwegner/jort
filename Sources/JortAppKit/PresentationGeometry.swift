import AppKit

/// Coordinates captured before painting. Zero overscan deliberately mounts only
/// the native viewport; TextKit owns fragment retention beyond its edges.
struct PresentationGeometry {
  static let overscanPoints: CGFloat = 0
  struct LineBand {
    let id: UUID
    let number: Int
    let frame: NSRect
    let textY: CGFloat
    let accessoryFrame: NSRect?
  }
  struct LineDescriptor {
    let id: UUID
    let number: Int
    let accessoryHeight: CGFloat
  }
  struct Fragment {
    let frame: NSRect
    let lines: [(offset: Int, bounds: NSRect)]
  }
  static func bands(in fragment: Fragment, descriptor: (Int) -> LineDescriptor?) -> [LineBand] {
    let bottom = fragment.lines.map { $0.bounds.maxY }.max() ?? fragment.frame.height
    return fragment.lines.compactMap { line in
      guard let value = descriptor(line.offset) else { return nil }
      return LineBand(
        id: value.id, number: value.number, frame: fragment.frame,
        textY: fragment.frame.minY + line.bounds.minY,
        accessoryFrame: value.accessoryHeight > 0
          ? NSRect(
            x: fragment.frame.minX, y: fragment.frame.minY + bottom,
            width: fragment.frame.width, height: value.accessoryHeight) : nil)
    }
  }
  struct Control: Equatable {
    let identity: String
    let frame: NSRect
    let accessibilityLabel: String?
    let order: Int
  }
  struct Snapshot {
    let epoch: UInt64
    let viewport: NSRect
    let bands: [LineBand]
  }
}
