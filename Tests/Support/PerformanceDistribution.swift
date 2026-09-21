import Foundation
import CryptoKit

/// Machine-readable evidence beside existing reports; never changes a test's gate.
enum PerformanceDistribution {
  static func report(_ name: String, fixture: String, text: String, samples: [Double], warmup: Int)
  {
    precondition(samples.count > warmup && warmup >= 0)
    let measured = Array(samples.dropFirst(warmup)).map { $0 * 1000 }
    let sorted = measured.sorted()
    func percentile(_ q: Double) -> Double {
      sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * q)) - 1)]
    }
    let phase: String
    switch name {
    case "native-first-paint": phase = "visible-text"
    case "prepared-convergence", "viewport-layout": phase = "prepared-presentation"
    case "transaction", "native-edit", "native-navigation": phase = "interaction"
    default: phase = "background-throughput"
    }
    let record: [String: Any] = [
      "phase": phase,
      "metric": name, "fixture": fixture,
      "fixtureSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }
        .joined(),
      "utf16Units": text.utf16.count, "warmup": warmup, "sampleCount": measured.count,
      "samplesMs": measured, "p50Ms": percentile(0.50),
      "p95Ms": percentile(0.95), "p99Ms": percentile(0.99),
      "pid": ProcessInfo.processInfo.processIdentifier,
    ]
    let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print("JORT_DISTRIBUTION " + String(decoding: data, as: UTF8.self))
  }
}
