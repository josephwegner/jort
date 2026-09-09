import AppKit
import JortDocument
import JortSettings

@MainActor private final class ToolActionButton: NSButton {
    var invoke: (() -> Void)?
    init(symbol: String, label: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        title = ""; isBordered = false; bezelStyle = .inline
        toolTip = label; setAccessibilityLabel(label)
        target = self; self.action = #selector(activate); invoke = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() { invoke?() }
}

@MainActor private final class ToolPromptView: NSView, NSTextViewDelegate {
    let input = NSTextView()
    private let scroll = NSScrollView()
    var changed: ((String) -> Void)?
    var submit: (() -> Void)?
    var dismiss: (() -> Void)?
    var multiline = true
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.systemTeal.cgColor; layer?.borderWidth = 1; layer?.cornerRadius = 6
        input.isRichText = false; input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        input.delegate = self; input.setAccessibilityLabel("Tool prompt")
        input.isVerticallyResizable = true; input.textContainer?.widthTracksTextView = true
        scroll.documentView = input; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        addSubview(scroll)
        let run = ToolActionButton(symbol: "play.fill", label: "Run") { [weak self] in self?.submit?() }
        let close = ToolActionButton(symbol: "xmark", label: "Dismiss prompt") { [weak self] in self?.dismiss?() }
        addSubview(run); addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 8, dy: 8); scroll.frame.size.height -= 26
        input.frame.size.width = scroll.contentSize.width
        input.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        subviews[1].frame = NSRect(x: bounds.width - 56, y: bounds.height - 28, width: 24, height: 24)
        subviews[2].frame = NSRect(x: bounds.width - 30, y: bounds.height - 28, width: 24, height: 24)
    }
    func textDidChange(_ notification: Notification) { changed?(input.string) }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismiss?(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { submit?(); return true }
            return !multiline
        }
        return false
    }
}

@MainActor private final class ToolScopeHandle: NSView {
    var moved: ((NSPoint) -> Void)?
    var focused: (() -> Void)?
    var key: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 2, yRadius: 2).fill()
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); focused?() }
    override func keyDown(with event: NSEvent) { if key?(event) != true { super.keyDown(with: event) } }
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }; moved?(superview.convert(event.locationInWindow, from: nil))
    }
}

/// Draws only viewport-intersecting canonical ranges. Controls remain separate
/// accessibility elements and never enter the document's text storage.
@MainActor final class ToolInvocationPresentation {
    weak var editor: EditorViewController?
    private var controls: [NSView] = []
    private var prompts: [UUID: ToolPromptView] = [:]
    private var completion: (NSRange, [ToolPackage], Int)?
    private var suppressedCompletion = false
    private var completionArmed = false
    private var refreshing = false
    private var shapes: [(NSBezierPath, NSColor)] = []
    private var styled: [NSRange] = []
    private let decorationAttribute = NSAttributedString.Key("JortToolDecoration")
    private var styledRevision: Int64 = -1
    private let documentFont: NSFont
    private var handles: [String: ToolScopeHandle] = [:]
    private var focusedBoundary: (UUID, Bool)?
    init(editor: EditorViewController) { self.editor = editor; documentFont = editor.textView.font ?? .monospacedSystemFont(ofSize: 15, weight: .regular) }
    func abandonCompletion() { completion = nil; completionArmed = false; suppressedCompletion = true }
    func armCommittedSlash() {
        completionArmed = editor?.toolController.focused() == nil
        suppressedCompletion = false
    }

    func escape() -> Bool {
        if completion != nil { completion = nil; suppressedCompletion = true; refresh(); return true }
        if let invocation = editor?.toolController.focused(), invocation.phase == .inputting {
            editor?.toolController.cancel(invocation.id); return true
        }
        return false
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let editor else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if key == "/" { completionArmed = editor.toolController.focused() == nil }
        if key == "\r", event.modifierFlags.contains(.shift) {
            if editor.view.window?.firstResponder is ToolScopeHandle, let (id, _) = focusedBoundary {
                editor.toolController.submit(id)
            } else if let invocation = editor.toolController.focused() { editor.toolController.submit(invocation.id) }
            return true
        }
        if let (range, packages, selected) = completion {
            if event.keyCode == 125 || event.keyCode == 126 {
                completion = (range, packages, max(0, min(packages.count - 1, selected + (event.keyCode == 125 ? 1 : -1))))
                refresh(recomputeCompletion: false); return true
            }
            if key == " " || key == "\r" {
                completion = nil; suppressedCompletion = true
                try? editor.toolController.accept(packages[selected], token: range, space: key == " ")
                return true
            }
        }
        let caretInvocation = editor.toolController.focused()
        let boundaryOwnsFocus = editor.view.window?.firstResponder is ToolScopeHandle
        if !boundaryOwnsFocus, focusedBoundary?.0 != caretInvocation?.id { focusedBoundary = nil }
        let focusedContext = focusedBoundary.flatMap { id, _ in editor.state.invocations.first { $0.id == id } } ?? caretInvocation
        if event.modifierFlags.contains([.option, .shift]), let invocation = focusedContext, invocation.inputMode == "contextual",
           let scope = invocation.scope.resolve(in: editor.state.lines), [123, 124, 125, 126].contains(event.keyCode) {
            let start = focusedBoundary?.0 == invocation.id ? focusedBoundary!.1 : false
            let offset = start ? scope.location : NSMaxRange(scope)
            let text = editor.state.text as NSString
            let next: Int
            if event.keyCode == 123 { next = offset > 0 ? text.rangeOfComposedCharacterSequence(at: offset - 1).location : 0 }
            else if event.keyCode == 124 { next = offset < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) : offset }
            else if event.keyCode == 126 { next = offset > 0 ? text.lineRange(for: NSRange(location: offset - 1, length: 0)).location : 0 }
            else { next = NSMaxRange(text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))) }
            try? editor.toolController.moveBoundary(invocation.id, start: start, to: next); return true
        }
        suppressedCompletion = false
        return false
    }

    private func findCompletion() {
        guard let editor, completionArmed, !suppressedCompletion, !editor.textView.hasMarkedText(), !editor.textView.isPasting,
              editor.textView.selectedRange().length == 0, editor.toolController.focused() == nil else { completion = nil; return }
        let text = editor.state.text as NSString, caret = editor.textView.selectedRange().location
        guard caret <= text.length else { completion = nil; return }
        let start = max(0, caret - 65)
        let prefix = text.substring(with: NSRange(location: start, length: caret - start))
        guard let slash = prefix.lastIndex(of: "/") else { completion = nil; return }
        let offset = start + prefix[..<slash].utf16.count
        guard offset == 0 || UnicodeScalar(text.character(at: offset - 1)).map({ CharacterSet.whitespacesAndNewlines.contains($0) }) == true else { completion = nil; return }
        let query = text.substring(with: NSRange(location: offset, length: caret - offset))
        let packages = editor.toolController.packages.filter { $0.manifest.command.hasPrefix(query) }
        completion = packages.isEmpty ? nil : (NSRange(location: offset, length: caret - offset), packages, 0)
    }

    func refresh(recomputeCompletion: Bool = true) {
        guard !refreshing, let editor, let storage = editor.textView.textStorage else { return }
        refreshing = true; defer { refreshing = false }
        controls.forEach { $0.removeFromSuperview() }; controls = []; shapes = []
        handles.values.forEach { $0.isHidden = true }
        var visiblePrompts = Set<UUID>()
        if recomputeCompletion { findCompletion() }
        let snapshot = editor.state
        if snapshot.invocations.isEmpty && styled.isEmpty && completion == nil {
            for prompt in prompts.values { prompt.removeFromSuperview() }
            prompts = [:]
            for handle in handles.values { handle.removeFromSuperview() }
            handles = [:]
            return
        }
        if styledRevision != snapshot.revision {
            // Attribute runs move with native edits; cached numeric ranges do not.
            var oldRuns: [NSRange] = []
            storage.enumerateAttribute(decorationAttribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil { oldRuns.append(range) }
            }
            storage.beginEditing()
            for range in oldRuns {
                storage.removeAttribute(.kern, range: range)
                storage.addAttribute(.font, value: documentFont, range: range)
                storage.removeAttribute(decorationAttribute, range: range)
            }
            styled = []
            for invocation in snapshot.invocations {
                guard let token = invocation.token.resolve(in: snapshot.lines), let scope = invocation.scope.resolve(in: snapshot.lines) else { continue }
                storage.addAttribute(.font, value: NSFontManager.shared.convert(documentFont, toHaveTrait: .boldFontMask), range: token)
                storage.addAttribute(decorationAttribute, value: true, range: token)
                styled.append(token)
                let output = invocation.output?.resolve(in: snapshot.lines)
                let leading = output.map { leadingActions($0, text: snapshot.text) } ?? false
                let controlOffset = output.map { leading ? $0.location : NSMaxRange($0) } ?? NSMaxRange(invocation.inputMode == "contextual" ? token : scope)
                if controlOffset > 0 && controlOffset <= storage.length {
                    let padding = (snapshot.text as NSString).rangeOfComposedCharacterSequence(at: controlOffset - 1)
                    storage.addAttribute(.kern, value: output?.length == 0 ? 78 : 54, range: padding); styled.append(padding)
                    storage.addAttribute(decorationAttribute, value: true, range: padding)
                }
            }
            storage.endEditing()
            styledRevision = snapshot.revision
            editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        for invocation in snapshot.invocations {
            guard let token = invocation.token.resolve(in: snapshot.lines), let scope = invocation.scope.resolve(in: snapshot.lines) else { continue }
            let output = invocation.output?.resolve(in: snapshot.lines)
            let leading = output.map { leadingActions($0, text: snapshot.text) } ?? false
            var sourceRects = connected(rects(scope))
            if output == nil, invocation.inputMode != "contextual", !sourceRects.isEmpty { sourceRects[sourceRects.count - 1].size.width += 27 }
            if let output, !sourceRects.isEmpty, invocation.inputMode != "contextual" {
                sourceRects[sourceRects.count - 1].size.width -= output.length == 0 ? 42 : leading ? 30 : 3
            }
            let color: NSColor = invocation.phase == .error ? .systemRed : invocation.message == nil ? .systemTeal : .systemOrange
            shapes.append((Self.union(sourceRects), color))
            let outputRects: [NSRect]
            if let output {
                var frames = connected(rects(output))
                if output.length == 0, let anchor = frames.first {
                    frames = [NSRect(x: anchor.minX - 36, y: anchor.minY, width: 78, height: anchor.height)]
                } else if !frames.isEmpty {
                    frames[0].origin.x += 3; frames[0].size.width -= 3
                    if leading { frames[0].origin.x -= 27; frames[0].size.width += 27 }
                    else { frames[frames.count - 1].size.width += 27 }
                }
                if let a = sourceRects.last, let b = frames.first, b.minY > a.minY {
                    let seam = NSRect(x: min(a.minX, b.minX), y: a.maxY - 2,
                        width: max(a.maxX, b.maxX) - min(a.minX, b.minX), height: max(4, b.minY - a.maxY + 4))
                    frames.insert(seam, at: 0)
                }
                outputRects = frames
                shapes.append((Self.union(frames), .systemPurple))
            } else { outputRects = [] }
            var contextControl = invocation.inputMode == "contextual" && output == nil ? rects(token).last : nil
            contextControl?.size.width += 27
            let leadingAnchor = leading ? rects(NSRange(location: output!.location, length: 0)).first : nil
            guard let anchor = (leadingAnchor ?? outputRects.last ?? contextControl ?? sourceRects.last) else { continue }
            let controlFrame = NSRect(x: leading ? anchor.minX - 21 : anchor.maxX - 50, y: anchor.minY, width: 50, height: max(24, anchor.height))
            switch invocation.phase {
            case .inputting:
                addButton("play.fill", "Run", frame: controlFrame) { [weak editor] in editor?.toolController.submit(invocation.id) }
            case .submitted: break
            case .processing:
                let spinner = NSProgressIndicator(frame: NSRect(x: controlFrame.minX, y: controlFrame.minY + 3, width: 18, height: 18))
                spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil); mount(spinner)
                addButton("xmark", "Cancel", frame: controlFrame.offsetBy(dx: 24, dy: 0)) { [weak editor] in editor?.toolController.cancel(invocation.id) }
            case .pending:
                if output?.length == 0 {
                    let empty = NSTextField(labelWithString: "∅"); empty.textColor = .secondaryLabelColor
                    empty.setAccessibilityLabel("Empty result"); empty.toolTip = "Empty result"
                    empty.frame = NSRect(x: anchor.minX + 4, y: anchor.minY + 3, width: 20, height: 22); mount(empty)
                }
                addButton("arrow.triangle.merge", "Merge", frame: controlFrame) { [weak editor] in try? editor?.toolController.merge(invocation.id) }
                addButton("xmark", "Dismiss", frame: controlFrame.offsetBy(dx: 24, dy: 0)) { [weak editor] in try? editor?.toolController.dismiss(invocation.id) }
            case .error:
                addButton("xmark", "Dismiss: \(invocation.message ?? "Execution error")", frame: controlFrame) { [weak editor] in try? editor?.toolController.dismiss(invocation.id) }
            }
            if invocation.inputMode == "contextual", invocation.phase == .inputting {
                for (start, offset) in [(true, scope.location), (false, NSMaxRange(scope))] {
                    guard let position = rects(NSRange(location: offset, length: 0)).first else { continue }
                    let handleKey = invocation.id.uuidString + (start ? ".start" : ".end")
                    let handle = handles[handleKey] ?? ToolScopeHandle(frame: .zero)
                    handles[handleKey] = handle
                    handle.isHidden = false
                    handle.frame = NSRect(x: position.minX - 7, y: position.minY, width: 14, height: 26)
                    handle.setAccessibilityRole(.slider)
                    handle.setAccessibilityLabel(start ? "Context start" : "Context end")
                    handle.moved = { [weak editor] point in
                        guard let editor else { return }
                        let index = editor.textView.characterIndexForInsertion(at: point)
                        try? editor.toolController.moveBoundary(invocation.id, start: start, to: index)
                    }
                    handle.focused = { [weak self] in self?.focusedBoundary = (invocation.id, start) }
                    handle.key = { [weak self] in self?.handle($0) ?? false }
                    if handle.superview == nil { editor.textView.addSubview(handle) }
                }
            }
            if invocation.inputMode.hasPrefix("ephemeral"), invocation.phase == .inputting, let tokenRect = rects(token).last {
                visiblePrompts.insert(invocation.id)
                let prompt = prompts[invocation.id] ?? ToolPromptView()
                let isNew = prompts[invocation.id] == nil
                prompts[invocation.id] = prompt
                prompt.isHidden = false
                if isNew { prompt.input.string = editor.toolController.prompts[invocation.id] ?? "" }
                prompt.multiline = invocation.inputMode == "ephemeralMultiline"
                let viewport = editor.textView.visibleRect
                let width = min(320, max(120, viewport.width - 16))
                // Prefer below/right. At a window edge keep the form usable and
                // retain a short attachment to the same document anchor.
                let x = max(viewport.minX + 8, min(tokenRect.maxX, viewport.maxX - width))
                prompt.frame = NSRect(x: x, y: tokenRect.maxY + 4, width: width, height: prompt.multiline ? 150 : 70)
                if x < tokenRect.maxX {
                    shapes.append((Self.union([NSRect(x: tokenRect.maxX - 2, y: tokenRect.maxY, width: 2, height: 5)]), .systemTeal))
                }
                prompt.changed = { [weak editor] in editor?.toolController.prompts[invocation.id] = $0 }
                prompt.submit = { [weak editor] in editor?.toolController.submit(invocation.id) }
                prompt.dismiss = { [weak editor] in editor?.toolController.cancel(invocation.id) }
                if prompt.superview == nil { editor.textView.addSubview(prompt) }
                if isNew { editor.view.window?.makeFirstResponder(prompt.input) }
            }
        }
        for (id, prompt) in prompts where !snapshot.invocations.contains(where: { $0.id == id && $0.phase == .inputting }) {
            if editor.view.window?.firstResponder === prompt.input { editor.view.window?.makeFirstResponder(editor.textView) }
            prompt.removeFromSuperview(); prompts.removeValue(forKey: id)
        }
        for (id, prompt) in prompts where !visiblePrompts.contains(id) { prompt.isHidden = true }
        for (key, handle) in handles where !snapshot.invocations.contains(where: { key.hasPrefix($0.id.uuidString) && $0.phase == .inputting }) {
            handle.removeFromSuperview(); handles.removeValue(forKey: key)
        }
        if let (range, packages, selected) = completion, let anchor = rects(range).last {
            for (index, package) in packages.prefix(8).enumerated() {
                let label = "\(package.manifest.command)  \(package.manifest.name)"
                let button = ToolActionButton(symbol: "", label: label) { [weak self, weak editor] in
                    self?.abandonCompletion()
                    try? editor?.toolController.accept(package, token: range, space: false)
                }
                button.title = "\(index == selected ? "› " : "")" + label; button.imagePosition = .noImage
                button.isBordered = true; button.bezelStyle = .smallSquare
                button.frame = NSRect(x: anchor.minX, y: anchor.maxY + 4 + CGFloat(index) * 28, width: 280, height: 28)
                mount(button)
            }
        }
        editor.textView.needsDisplay = true
    }

    private func mount(_ view: NSView) { editor?.textView.addSubview(view); controls.append(view) }
    private func leadingActions(_ output: NSRange, text: String) -> Bool {
        // Long results keep their actions at the source/output seam rather than
        // requiring a scroll to the end. Short inline results retain trailing actions.
        output.length > 40 || (text as NSString).substring(with: output).contains("\n")
    }
    private func connected(_ frames: [NSRect]) -> [NSRect] {
        guard frames.count > 1 else { return frames }
        var result: [NSRect] = []
        for (index, frame) in frames.enumerated() {
            if index > 0 {
                let previous = frames[index - 1]
                if frame.minY > previous.minY {
                    result.append(NSRect(x: min(previous.minX, frame.minX), y: previous.maxY - 1,
                        width: max(previous.maxX, frame.maxX) - min(previous.minX, frame.minX),
                        height: max(2, frame.minY - previous.maxY + 2)))
                }
            }
            result.append(frame)
        }
        return result
    }
    private func addButton(_ symbol: String, _ label: String, frame: NSRect, action: @escaping () -> Void) {
        let button = ToolActionButton(symbol: symbol, label: label, action: action)
        button.frame = NSRect(x: frame.minX, y: frame.minY, width: 24, height: max(24, frame.height)); mount(button)
    }
    private func rects(_ range: NSRange) -> [NSRect] {
        editor?.linePresentation.canonicalRects(for: range).map { frame in
            var frame = frame.insetBy(dx: -3, dy: 0)
            if frame.minY < 0.5 { frame.size.height -= 0.5 - frame.minY; frame.origin.y = 0.5 }
            return frame
        } ?? []
    }
    func geometry(for range: NSRange) -> [NSRect] { rects(range) }
    func draw(_ rect: NSRect) {
        for (path, color) in shapes where path.elementCount > 0 && path.bounds.intersects(rect) {
            color.withAlphaComponent(0.16).setFill(); path.fill()
            color.withAlphaComponent(0.65).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    /// Trace the union's boundary on a coordinate grid, omitting every shared edge.
    static func union(_ rectangles: [NSRect]) -> NSBezierPath {
        let rects = rectangles.filter { $0.width > 0 && $0.height > 0 }
        let result = NSBezierPath()
        guard !rects.isEmpty else { return result }
        let xs = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set(rects.flatMap { [$0.minY, $0.maxY] })).sorted()
        struct Point: Hashable { let x: Int; let y: Int }
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
            if !occupied.contains(Point(x: p.x + 1, y: p.y)) { edges[Point(x: p.x + 1, y: p.y)] = Point(x: p.x + 1, y: p.y + 1) }
            if !occupied.contains(Point(x: p.x, y: p.y + 1)) { edges[Point(x: p.x + 1, y: p.y + 1)] = Point(x: p.x, y: p.y + 1) }
            if !occupied.contains(Point(x: p.x - 1, y: p.y)) { edges[Point(x: p.x, y: p.y + 1)] = p }
        }
        while let start = edges.keys.first {
            var points: [NSPoint] = []
            var current = start
            while let next = edges.removeValue(forKey: current) {
                points.append(NSPoint(x: xs[current.x], y: ys[current.y])); current = next
                if current == start { break }
            }
            guard points.count >= 3 else { continue }
            // Remove collinear grid vertices before rounding only boundary corners.
            points = points.indices.compactMap { index in
                let p = points[(index + points.count - 1) % points.count], c = points[index], n = points[(index + 1) % points.count]
                return p.x == c.x && c.x == n.x || p.y == c.y && c.y == n.y ? nil : c
            }
            guard points.count >= 3 else { continue }
            for index in points.indices {
                let p = points[(index + points.count - 1) % points.count], c = points[index], n = points[(index + 1) % points.count]
                let before = hypot(c.x - p.x, c.y - p.y), after = hypot(n.x - c.x, n.y - c.y)
                let radius = min(4, min(before, after) / 2)
                let a = NSPoint(x: c.x + (p.x - c.x) * radius / before, y: c.y + (p.y - c.y) * radius / before)
                let b = NSPoint(x: c.x + (n.x - c.x) * radius / after, y: c.y + (n.y - c.y) * radius / after)
                if index == 0 { result.move(to: a) } else { result.line(to: a) }
                result.curve(to: b, controlPoint1: c, controlPoint2: c)
            }
            result.close()
        }
        return result
    }
}
