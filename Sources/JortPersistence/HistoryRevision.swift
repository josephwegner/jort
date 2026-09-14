import Foundation
import Compression
import JortDocument

/// History identity is independent of the live document generation and SQLite row order.
public struct HistoryRevisionMetadata: Codable, Equatable, Sendable {
  public let id: UUID
  public let documentID: UUID
  public let generation: Int64
  public let timestamp: Date
  public let reason: String
  public let milestone: Bool
  public let stateHash: String
}

public struct HistoryRevision: Equatable, Sendable {
  public let metadata: HistoryRevisionMetadata
  public let snapshot: DocumentSnapshot
}

public struct HistoryEntry: Equatable, Sendable {
  /// Monotonic retention order, independent of wall-clock changes.
  public let sequence: Int64
  /// A damaged metadata row stays in the list as unavailable, without hiding neighbors.
  public let metadata: HistoryRevisionMetadata?
  public let storedBytes: Int
}

public struct HistorySettings: Codable, Equatable, Sendable {
  public var byteBudget: Int
  public var minimumRecentCount: Int
  public var idleInterval: TimeInterval
  private var policyVersion = 2
  private enum CodingKeys: String, CodingKey {
    case byteBudget, minimumRecentCount, idleInterval, policyVersion
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    byteBudget = try values.decode(Int.self, forKey: .byteBudget)
    minimumRecentCount = try values.decode(Int.self, forKey: .minimumRecentCount)
    idleInterval = try values.decode(TimeInterval.self, forKey: .idleInterval)
    // Upgrade the former default, preserving explicitly different intervals.
    if try values.decodeIfPresent(Int.self, forKey: .policyVersion) == nil, idleInterval == 30 {
      idleInterval = 60
    }
  }

  public init(
    byteBudget: Int = 256 * 1024 * 1024, minimumRecentCount: Int = 20,
    idleInterval: TimeInterval = 60
  ) {
    self.byteBudget = byteBudget
    self.minimumRecentCount = minimumRecentCount
    self.idleInterval = idleInterval
  }

  func validate() throws {
    guard byteBudget > 0, minimumRecentCount > 0, minimumRecentCount <= 100_000,
      idleInterval.isFinite, idleInterval >= 1, idleInterval <= 86_400
    else {
      throw StoreError.invalidPayload
    }
  }
}

/// Immutable, bounded wire format. Callers run serialization on the storage actor.
/// Checksums detect corruption, not malicious tampering by someone with file access.
enum HistoryRevisionFormat {
  static let version = 1
  static let maximumBytes = PersistenceFormat.maximumBytes * 2
  private struct Header: Decodable { let version: Int }
  private struct Content: Codable {
    let metadata: HistoryRevisionMetadata
    let compression: String
    let uncompressedBytes: Int
    let payloadHash: String
    let payload: Data
  }
  private struct Envelope: Codable {
    let version: Int
    let content: Content
    let checksum: String
  }

  static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  /// Generation is bookkeeping: an exact undo back to a retained state deduplicates.
  /// Text, document/line/landmark identities and line timestamps remain in the hash.
  static func stateHash(
    _ snapshot: DocumentSnapshot, payloadVersion: Int = PersistenceFormat.payloadVersion
  ) throws -> String {
    let state = DocumentSnapshot(
      documentID: snapshot.documentID, text: snapshot.text,
      revision: 0, lines: snapshot.lines, landmarks: snapshot.landmarks,
      invocations: snapshot.invocations)
    return PersistenceFormat.checksum(try PersistenceFormat.encode(state, version: payloadVersion))
  }

  static func encode(
    _ snapshot: DocumentSnapshot, reason: String, timestamp: Date,
    milestone: Bool = false, id: UUID = UUID()
  ) throws -> (Data, HistoryRevisionMetadata) {
    let payload = try PersistenceFormat.encode(snapshot)
    let metadata = HistoryRevisionMetadata(
      id: id, documentID: snapshot.documentID,
      generation: snapshot.revision, timestamp: timestamp, reason: reason,
      milestone: milestone, stateHash: try stateHash(snapshot))
    try validate(metadata)
    // Incompressible data falls back to raw bytes; the envelope records that choice.
    var compressed = Data(count: payload.count)
    let written = compressed.withUnsafeMutableBytes { output in
      payload.withUnsafeBytes { input in
        compression_encode_buffer(
          output.bindMemory(to: UInt8.self).baseAddress!, output.count,
          input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
      }
    }
    let useCompression = written > 0 && written < payload.count
    if useCompression { compressed.count = written }
    let content = Content(
      metadata: metadata, compression: useCompression ? "lzfse" : "none",
      uncompressedBytes: payload.count, payloadHash: PersistenceFormat.checksum(payload),
      payload: useCompression ? compressed : payload)
    let envelope = Envelope(
      version: version, content: content,
      checksum: PersistenceFormat.checksum(try encodeJSON(content)))
    let data = try encodeJSON(envelope)
    guard data.count <= maximumBytes else { throw StoreError.sizeLimit }
    return (data, metadata)
  }

  static func decode(_ data: Data) throws -> HistoryRevision {
    guard data.count <= maximumBytes else { throw StoreError.sizeLimit }
    do {
      let decoder = JSONDecoder()
      let header = try decoder.decode(Header.self, from: data)
      guard header.version <= version else { throw StoreError.unsupportedVersion }
      guard header.version == version else { throw StoreError.invalidPayload }
      let envelope = try decoder.decode(Envelope.self, from: data)
      let content = envelope.content
      try validate(content.metadata)
      guard envelope.checksum == PersistenceFormat.checksum(try encodeJSON(content)),
        content.uncompressedBytes > 0,
        content.uncompressedBytes <= PersistenceFormat.maximumBytes
      else { throw StoreError.invalidPayload }
      let payload: Data
      switch content.compression {
      case "none": payload = content.payload
      case "lzfse":
        guard !content.payload.isEmpty else { throw StoreError.invalidPayload }
        // One extra byte detects output that exceeds the declared length.
        var decoded = Data(count: content.uncompressedBytes + 1)
        let count = decoded.withUnsafeMutableBytes { output in
          content.payload.withUnsafeBytes { input in
            compression_decode_buffer(
              output.bindMemory(to: UInt8.self).baseAddress!, output.count,
              input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
          }
        }
        guard count == content.uncompressedBytes else { throw StoreError.invalidPayload }
        decoded.count = count
        payload = decoded
      default: throw StoreError.unsupportedVersion
      }
      guard payload.count == content.uncompressedBytes,
        PersistenceFormat.checksum(payload) == content.payloadHash
      else { throw StoreError.invalidPayload }
      let decoded = try PersistenceFormat.decode(payload)
      let snapshot = decoded.snapshot
      guard snapshot.documentID == content.metadata.documentID,
        snapshot.revision == content.metadata.generation,
        try stateHash(snapshot, payloadVersion: decoded.version) == content.metadata.stateHash
      else { throw StoreError.invalidPayload }
      return HistoryRevision(metadata: content.metadata, snapshot: snapshot)
    } catch let error as StoreError { throw error } catch { throw StoreError.invalidPayload }
  }

  static func validate(_ metadata: HistoryRevisionMetadata) throws {
    guard metadata.generation >= 0, metadata.timestamp.timeIntervalSinceReferenceDate.isFinite,
      !metadata.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      metadata.reason.utf8.count <= 256, metadata.stateHash.count == 64,
      metadata.stateHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      throw StoreError.invalidPayload
    }
  }
}
