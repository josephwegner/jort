import Foundation
import os

/// Stable, content-free Instruments boundaries. Revisions are correlation values only.
public enum DocumentInstrumentation {
  private static let log = OSLog(subsystem: "dev.jort.document", category: .pointsOfInterest)
  public struct Interval: Sendable {
    fileprivate let name: StaticString
    fileprivate let id: OSSignpostID
  }
  public static func begin(_ name: StaticString, revision: Int64 = -1) -> Interval {
    let id = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: name, signpostID: id, "revision=%lld", revision)
    return Interval(name: name, id: id)
  }
  public static func end(_ interval: Interval) {
    os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
  }
  public static func event(_ name: StaticString, revision: Int64) {
    os_signpost(.event, log: log, name: name, "revision=%lld", revision)
  }
  /// Opt-in test scope. Child tasks inherit it; detached workers must receive it explicitly.
  @TaskLocal public static var recorder: DocumentWorkRecorder?
  public static func count(_ counter: DocumentWorkRecorder.Counter, _ amount: Int = 1) {
    recorder?.add(counter, amount)
  }
}

/// Test diagnostics, never a global resettable accumulator.
public final class DocumentWorkRecorder: Sendable {
  public enum Counter: String, CaseIterable, Sendable {
    case visitedLines, visitedChunks, visitedIndexNodes, copiedLineRecords
    case allocatedPayloadBytes, flattenedUTF16Units, flattenCalls, completeValidations
    case allocatedIndexNodes, allocatedChunks
    case retainedStorageObjects, releasedStorageObjects, retainedStorageBytes, releasedStorageBytes
    case visibleFragments
  }
  private let counts = OSAllocatedUnfairLock(initialState: [Counter: Int]())
  public init() {}
  fileprivate func add(_ counter: Counter, _ amount: Int) {
    precondition(amount >= 0)
    counts.withLock { $0[counter, default: 0] += amount }
  }
  public var snapshot: [Counter: Int] { counts.withLock { $0 } }
}

/// A scoped collector survives until its last observed allocation is released.
/// The token never references storage, so observing lifetime cannot retain a root.
final class DocumentStorageLifetime: Sendable {
  private let recorder: DocumentWorkRecorder
  private let bytes: Int
  static func track(bytes: Int) -> DocumentStorageLifetime? {
    guard let recorder = DocumentInstrumentation.recorder else { return nil }
    return DocumentStorageLifetime(recorder: recorder, bytes: bytes)
  }
  private init(recorder: DocumentWorkRecorder, bytes: Int) {
    self.recorder = recorder
    self.bytes = bytes
    recorder.add(.retainedStorageObjects, 1)
    recorder.add(.retainedStorageBytes, bytes)
  }
  deinit {
    recorder.add(.releasedStorageObjects, 1)
    recorder.add(.releasedStorageBytes, bytes)
  }
}
