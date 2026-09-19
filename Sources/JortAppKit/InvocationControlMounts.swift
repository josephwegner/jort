import AppKit

/// Owns only mounted native controls. Keys include invocation generation and action.
@MainActor final class InvocationControlMounts {
  private var mounted: [String: NSView] = [:]
  private var desired = Set<String>()
  private(set) var ordered: [NSView] = []
  private(set) var snapshot: [PresentationGeometry.Control] = []
  func begin() {
    desired = []
    ordered = []
  }
  func view<T: NSView>(key: String, in parent: NSView, make: () -> T) -> T {
    let view = mounted[key] as? T ?? make()
    mounted[key] = view
    desired.insert(key)
    ordered.append(view)
    if view.superview !== parent { parent.addSubview(view) }
    return view
  }
  func finish() {
    let keys = Dictionary(
      uniqueKeysWithValues: mounted.map { (ObjectIdentifier($0.value), $0.key) })
    snapshot = ordered.enumerated().compactMap { index, view in
      guard let key = keys[ObjectIdentifier(view)] else { return nil }
      return .init(
        identity: key, frame: view.frame, accessibilityLabel: view.accessibilityLabel(),
        order: index)
    }
    for key in mounted.keys.filter({ !desired.contains($0) }) {
      if let spinner = mounted[key] as? NSProgressIndicator { spinner.stopAnimation(nil) }
      mounted.removeValue(forKey: key)?.removeFromSuperview()
    }
  }
}
