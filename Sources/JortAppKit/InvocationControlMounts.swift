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
  func remove(for invocationIDs: Set<UUID>) -> [NSView] {
    let keys = mounted.keys.filter { key in
      invocationIDs.contains { key.hasPrefix($0.uuidString + ".") }
    }
    let removed = keys.compactMap { key -> NSView? in
      guard let view = mounted.removeValue(forKey: key) else { return nil }
      if let spinner = view as? NSProgressIndicator { spinner.stopAnimation(nil) }
      view.removeFromSuperview()
      return view
    }
    let identities = Set(removed.map(ObjectIdentifier.init))
    desired.subtract(keys)
    ordered.removeAll { identities.contains(ObjectIdentifier($0)) }
    snapshot.removeAll { control in
      invocationIDs.contains { control.identity.hasPrefix($0.uuidString + ".") }
    }
    return removed
  }
}
