// Standalone AppKit reproduction: no Jort code and no XCTest host.
// Compile with: xcrun swiftc -parse-as-library native-window-animation.swift -o /tmp/native-window-animation
// Run with OS_ACTIVITY_DT_MODE=YES. Pass --manual-runloop to mimic a test host
// that does not call NSApplication.run(), and --no-animation for the control run.
import AppKit

@main
struct NativeWindowAnimationProbe {
  @MainActor static func main() {
    let application = NSApplication.shared
    let disableAnimation = CommandLine.arguments.contains("--no-animation")
    let manualRunLoop = CommandLine.arguments.contains("--manual-runloop")
    var finished = false
    print("Window animation: \(disableAnimation ? "disabled" : "default")")
    print("Run loop: \(manualRunLoop ? "manual" : "NSApplication.run")")
    Task { @MainActor in
      for _ in 0..<5 {
        await cycle(disableAnimation: disableAnimation)
        try? await Task.sleep(for: .milliseconds(150))
      }
      try? await Task.sleep(for: .milliseconds(500))
      finished = true
      if !manualRunLoop { application.terminate(nil) }
    }
    if manualRunLoop {
      while !finished {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      }
    } else {
      application.run()
    }
  }

  @MainActor private static func cycle(disableAnimation: Bool) async {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    if disableAnimation { window.animationBehavior = .none }
    let controller = NSViewController()
    controller.view = NSTextView(usingTextLayoutManager: true)
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    try? await Task.sleep(for: .milliseconds(80))
    window.orderOut(nil)
    window.close()
    window.contentViewController = nil
  }
}
