import JortToolRuntime
import JortToolContracts
import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor class ToolInvocationTestCase: StoreTestCase {
  func editor(directory: URL? = nil) async throws -> (EditorViewController, NSWindow) {
    ApplicationTheme.install()
    let directory =
      directory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("ToolEditor-\(UUID())")
    let editor = EditorViewController(persistence: ownPersistence(directory: directory))
    editor.toolInvocationCoordinator = ToolInvocationCoordinator(executor: ToolExecutorDispatcher())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // Rapid fixture teardown must not release AppKit window animations during a CA commit.
    window.animationBehavior = .none
    addTeardownBlock { @MainActor in
      window.close()
      window.contentViewController = nil
    }
    window.contentViewController = editor
    window.setContentSize(NSSize(width: 600, height: 400))
    window.makeKeyAndOrderFront(nil)
    for _ in 0..<500 where editor.startupPhase != .ready {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(editor.startupPhase, .ready)
    XCTAssertTrue(editor.textView.isEditable)
    return (editor, window)
  }
  func key(
    _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
    in editor: EditorViewController, window: NSWindow
  ) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    editor.textView.keyDown(with: event)
  }
  func package(_ command: String, mode: ToolInputMode = .contained, output: String = "6")
    -> ToolPackage
  {
    let encoded = String(data: try! JSONEncoder().encode(output), encoding: .utf8)!
    return .init(
      manifest: .init(
        id: "dev.test." + command, name: command, command: "/" + command, inputMode: mode),
      source: "export default async function(input) { return {output: \(encoded)}; }")
  }
  func pending(_ editor: EditorViewController) async throws {
    for _ in 0..<500 {
      if editor.state.invocations.first?.phase == .pending {
        await settlePresentationAsync(editor)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Tool did not enter pending: \(editor.state.invocations)")
  }
  func pending(_ editor: EditorViewController, id: UUID) async throws {
    for _ in 0..<500 {
      if editor.state.invocations.first(where: { $0.id == id })?.phase == .pending {
        await settlePresentationAsync(editor)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Tool did not enter pending: \(editor.state.invocations)")
  }
  func error(_ editor: EditorViewController, id: UUID) async throws {
    for _ in 0..<500 {
      if editor.state.invocations.first(where: { $0.id == id })?.phase == .error { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Tool did not enter error: \(editor.state.invocations)")
  }

  /// Captures the existing phase authority before extraction. Illegal repeat actions
  /// must leave canonical text and the completed generation unchanged.
  func persistedPendingSnapshot(package: ToolPackage, packageVersion: Int, output: String)
    throws -> DocumentSnapshot
  {
    let model = try DocumentCoordinator()
    let text = package.manifest.command + output
    let plain = try model.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(
          text: text, range: NSRange(location: 0, length: 0), replacementLength: text.utf16.count))
    ).after
    let token = NSRange(location: 0, length: package.manifest.command.utf16.count)
    var invocation = ToolInvocation(
      packageID: package.manifest.id, packageVersion: packageVersion,
      entryContract: package.manifest.entryContract, inputMode: package.manifest.inputMode.rawValue,
      outputOperation: package.manifest.outputOperation.rawValue, command: package.manifest.command,
      token: try .init(token, lines: plain.lines), scope: try .init(token, lines: plain.lines),
      sourceHash: ToolInvocation.hash(package.manifest.command))
    invocation.phase = .pending
    invocation.output = try .init(
      NSRange(location: NSMaxRange(token), length: output.utf16.count), lines: plain.lines)
    invocation.outputHash = ToolInvocation.hash(output)
    return DocumentSnapshot(
      documentID: plain.documentID, text: text, revision: plain.revision,
      lines: plain.lines, invocations: [invocation])
  }

  func modelPackage(mode: ToolInputMode) -> ToolPackage {
    var manifest = ToolManifest(
      id: "dev.test.model", name: "Model", command: "/model", inputMode: mode)
    manifest.schemaVersion = 2
    manifest.executor = .model
    manifest.modelID = ModelCatalog.defaultModelID
    return .init(manifest: manifest, instructions: "Transform only the input.")
  }
}
