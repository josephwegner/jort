import AppKit

@MainActor final class RulerControlMounts {
  private var buttons: [UUID: NSButton] = [:]
  func reconcile(ids: Set<UUID>) {
    for id in buttons.keys.filter({ !ids.contains($0) }) {
      buttons.removeValue(forKey: id)?.removeFromSuperview()
    }
  }
  func button(for id: UUID, in parent: NSView, make: () -> NSButton) -> NSButton {
    if let button = buttons[id] { return button }
    let button = make()
    buttons[id] = button
    parent.addSubview(button)
    return button
  }
}
