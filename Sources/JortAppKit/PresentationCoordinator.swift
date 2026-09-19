import AppKit

struct PresentationDirtyReasons: OptionSet, Sendable {
  let rawValue: UInt16
  static let document = Self(rawValue: 1 << 0)
  static let lifecycle = Self(rawValue: 1 << 1)
  static let layout = Self(rawValue: 1 << 2)
  static let viewport = Self(rawValue: 1 << 3)
  static let window = Self(rawValue: 1 << 4)
  static let appearance = Self(rawValue: 1 << 5)
  static let accessibility = Self(rawValue: 1 << 6)
  static let interaction = Self(rawValue: 1 << 7)
  static let storage = Self(rawValue: 1 << 8)
}

/// One next-turn scheduler per workspace. Painting never calls this owner.
@MainActor final class PresentationCoordinator {
  struct State: Equatable {
    let epoch: UInt64
    let committedEpoch: UInt64
    let reasons: PresentationDirtyReasons
    let scheduled: Bool
    let reconciling: Bool
    let passes: Int
  }
  private(set) var epoch: UInt64 = 0
  private(set) var committedEpoch: UInt64 = 0
  private var reasons: PresentationDirtyReasons = []
  private var scheduled = false
  private var reconciling = false
  private var passes = 0
  var prepare: ((PresentationDirtyReasons) -> (() -> Void)?)?
  var state: State {
    State(
      epoch: epoch, committedEpoch: committedEpoch, reasons: reasons,
      scheduled: scheduled, reconciling: reconciling, passes: passes)
  }
  func invalidate(_ reason: PresentationDirtyReasons) {
    epoch &+= 1
    reasons.formUnion(reason)
    schedule()
  }
  private func schedule() {
    guard !scheduled, !reconciling else { return }
    scheduled = true
    RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
      MainActor.assumeIsolated { self?.reconcile() }
    }
  }
  private func reconcile() {
    scheduled = false
    guard !reconciling, !reasons.isEmpty else { return }
    reconciling = true
    let capturedEpoch = epoch, capturedReasons = reasons
    reasons = []
    passes += 1
    let commit = prepare?(capturedReasons)
    if capturedEpoch == epoch, let commit {
      commit()
      committedEpoch = capturedEpoch
    } else if capturedEpoch != epoch {
      reasons.formUnion(capturedReasons)
    }
    reconciling = false
    if !reasons.isEmpty { schedule() }
  }
}
