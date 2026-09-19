import AppKit
import JortDocument

/// Native overlay actions carry their originating invocation projection. The
/// adapter validates generation before routing them to the headless lifecycle.
enum InvocationOverlayAction {
  case prompt(UUID, String), submit(UUID), cancel(UUID)
  case adjustBoundary(UUID, Bool, Int), moveBoundary(UUID, Bool, NSPoint)
  case focusBoundary(UUID, Bool)
}

@MainActor final class InvocationOverlayCoordinator {
  private weak var textView: JortTextView?
  private weak var parent: NSView?
  private var prompts: [UUID: ToolPromptView] = [:]
  private var handles: [String: ToolScopeHandle] = [:]
  private var knownPrompts = Set<UUID>()
  private var visiblePrompts = Set<UUID>()
  private var visibleHandles = Set<String>()
  var send: ((InvocationOverlayAction) -> Void)?
  var key: ((NSEvent) -> Bool)?
  init(textView: JortTextView, parent: NSView) {
    self.textView = textView
    self.parent = parent
  }
  func begin() {
    visiblePrompts = []
    visibleHandles = []
  }
  func reconcile(
    invocation: ToolInvocation, snapshot: DocumentSnapshot,
    token: NSRange, scope: NSRange, sourceEndsLine: Bool, tokenRect: NSRect?,
    boundaries: [(Bool, Int, NSRect)], promptValue: String?, isCurrent: @escaping () -> Bool
  ) -> (views: [NSView], connectors: [NSRect]) {
    guard let textView, let parent else { return ([], []) }
    var views: [NSView] = [], connectors: [NSRect] = []
    if invocation.inputMode == "contextual", invocation.phase == .inputting {
      for (start, offset, position) in boundaries {
        let key = invocation.id.uuidString + (start ? ".start" : ".end")
        visibleHandles.insert(key)
        let handle = handles[key] ?? ToolScopeHandle(frame: .zero)
        handles[key] = handle
        handle.isHidden = false
        handle.isStart = start
        handle.toolTip =
          start
          ? LocalizedCopy.text(
            "ToolInvocationPresentation.context_start_drag_to_choose_source_text",
            fallback: "Context start — drag to choose source text")
          : LocalizedCopy.text(
            "ToolInvocationPresentation.context_end_drag_to_choose_source_text",
            fallback: "Context end — drag to choose source text")
        let gap: CGFloat = !start && offset == NSMaxRange(token) && !sourceEndsLine ? 27 : 0
        handle.frame = NSRect(
          x: position.minX - 5 - gap, y: max(0, position.minY - 7), width: 16,
          height: max(30, position.height + 7))
        handle.setAccessibilityRole(.slider)
        handle.setAccessibilityElement(true)
        handle.setAccessibilityLabel(
          start
            ? LocalizedCopy.text(
              "ToolInvocationPresentation.context_start", fallback: "Context start")
            : LocalizedCopy.text("ToolInvocationPresentation.context_end", fallback: "Context end"))
        handle.setAccessibilityValue(NSNumber(value: offset))
        handle.setAccessibilityMinValue(NSNumber(value: 0))
        handle.setAccessibilityMaxValue(NSNumber(value: snapshot.text.utf16.count))
        handle.adjusted = { [weak self] direction in
          guard isCurrent() else { return }
          self?.send?(.adjustBoundary(invocation.id, start, direction))
        }
        handle.moved = { [weak self] point in
          guard isCurrent() else { return }
          self?.send?(.moveBoundary(invocation.id, start, point))
        }
        handle.focused = { [weak self] in
          guard isCurrent() else { return }
          self?.send?(.focusBoundary(invocation.id, start))
        }
        handle.key = { [weak self] in self?.key?($0) ?? false }
        if handle.superview !== textView {
          textView.addSubview(handle, positioned: .above, relativeTo: nil)
        }
        views.append(handle)
      }
    }
    if invocation.inputMode.hasPrefix("ephemeral"), invocation.phase == .inputting, let tokenRect {
      visiblePrompts.insert(invocation.id)
      let prompt = prompts[invocation.id] ?? ToolPromptView()
      let isNew = prompts[invocation.id] == nil
      let firstAppearance = knownPrompts.insert(invocation.id).inserted
      prompts[invocation.id] = prompt
      prompt.isHidden = false
      if isNew { prompt.input.string = promptValue ?? "" }
      prompt.multiline = invocation.inputMode == "ephemeralMultiline"
      let viewport = textView.visibleRect
      let width = min(320, max(120, viewport.width - 16))
      let x = max(viewport.minX + 8, min(tokenRect.maxX, viewport.maxX - width))
      let height = min(prompt.multiline ? 150.0 : 70.0, viewport.height)
      let below = tokenRect.maxY + 4
      let y =
        below + height <= viewport.maxY ? below : max(viewport.minY, tokenRect.minY - height - 4)
      prompt.frame = parent.convert(
        NSRect(x: x, y: y, width: width, height: height), from: textView)
      if x < tokenRect.maxX {
        connectors.append(NSRect(x: tokenRect.maxX - 2, y: tokenRect.maxY, width: 2, height: 5))
      }
      prompt.changed = { [weak self] value in
        guard isCurrent() else { return }
        self?.send?(.prompt(invocation.id, value))
      }
      prompt.submit = { [weak self] in
        guard isCurrent() else { return }
        self?.send?(.submit(invocation.id))
      }
      prompt.dismiss = { [weak self] in
        guard isCurrent() else { return }
        self?.send?(.cancel(invocation.id))
      }
      if prompt.superview !== parent {
        parent.addSubview(prompt, positioned: .above, relativeTo: nil)
      }
      if firstAppearance { parent.window?.makeFirstResponder(prompt.input) }
      views.append(prompt)
    }
    return (views, connectors)
  }
  func finish(snapshot: DocumentSnapshot) -> [NSView] {
    var retainedFocus: [NSView] = []
    let valid = Set(snapshot.invocations.filter { $0.phase == .inputting }.map(\.id))
    knownPrompts.formIntersection(valid)
    for id in prompts.keys.filter({ !valid.contains($0) }) {
      guard let prompt = prompts.removeValue(forKey: id) else { continue }
      if parent?.window?.firstResponder === prompt.input {
        parent?.window?.makeFirstResponder(textView)
      }
      prompt.removeFromSuperview()
    }
    for id in prompts.keys.filter({ !visiblePrompts.contains($0) }) {
      guard let prompt = prompts[id] else { continue }
      if parent?.window?.firstResponder === prompt.input {
        retainedFocus.append(prompt)
      } else {
        prompts.removeValue(forKey: id)?.removeFromSuperview()
      }
    }
    for key in handles.keys.filter({ key in !valid.contains(where: { key.hasPrefix($0.uuidString) })
    }) {
      guard let handle = handles.removeValue(forKey: key) else { continue }
      if parent?.window?.firstResponder === handle { parent?.window?.makeFirstResponder(textView) }
      handle.removeFromSuperview()
    }
    for key in handles.keys.filter({ !visibleHandles.contains($0) }) {
      if parent?.window?.firstResponder !== handles[key] {
        handles.removeValue(forKey: key)?.removeFromSuperview()
      }
    }
    return retainedFocus
  }
}
