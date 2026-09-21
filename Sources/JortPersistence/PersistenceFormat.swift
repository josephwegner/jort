import Foundation
import CryptoKit
import JortDocument

public enum StoreError: Error, Equatable, Sendable {
  case sqlite(Int32, String)
  case unsupportedVersion, malformedSchema, invalidPayload, checksumMismatch, sizeLimit, ownership,
    io(String),
    injected(String)
  public var recoverableCorruption: Bool {
    switch self {
    case .sqlite(let code, _): return code == 11 || code == 26
    case .invalidPayload, .checksumMismatch: return true
    default: return false
    }
  }
}
public enum PersistenceFormat {
  public static let sqliteVersion = 5
  public static let payloadVersion = 4
  public static let maximumBytes = 64 * 1024 * 1024
  private struct Header: Decodable {
    let formatVersion: Int?
    let schemaVersion: Int?
  }
  private struct LegacyV1: Decodable {
    let schemaVersion: Int
    let text: String
    let revision: Int64
    let lines: [LineMeta]
  }
  private struct Envelope: Codable {
    let formatVersion: Int
    let document: Payload
    let checksum: String?
    var annotationChecksum: String? = nil
  }
  private struct Payload: Codable {
    let id: UUID
    let content: String
    let liveRevision: Int64
    let lines: [LineMeta]
    let landmarks: [Landmark]
    var invocations: [ToolInvocation]?
    enum CodingKeys: String, CodingKey {
      case id, content, liveRevision, lines, landmarks, invocations
    }
    init(_ snapshot: DocumentSnapshot, text: String, lines: [LineMeta], revision: Int64?) {
      id = snapshot.documentID
      content = text
      liveRevision = revision ?? snapshot.revision
      self.lines = lines
      landmarks = snapshot.orderedLandmarks
      invocations = snapshot.invocations.isEmpty ? nil : snapshot.invocations
    }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(UUID.self, forKey: .id)
      content = try values.decode(String.self, forKey: .content)
      liveRevision = try values.decode(Int64.self, forKey: .liveRevision)
      lines = try values.decode([LineMeta].self, forKey: .lines)
      landmarks = try values.decode([Landmark].self, forKey: .landmarks)
      invocations = try? values.decodeIfPresent([ToolInvocation].self, forKey: .invocations)
    }
  }
  private struct LegacyLandmark: Decodable {
    let id: LandmarkID
    let lineID: UUID
    let emoji: String
  }
  private struct LegacyEnvelope: Decodable {
    struct Document: Decodable {
      let id: UUID
      let content: String
      let liveRevision: Int64
      let lines: [LineMeta]
      let landmarks: [LegacyLandmark]?
    }
    let document: Document
  }
  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
  public static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func encode(_ snapshot: DocumentSnapshot, version: Int = payloadVersion) throws
    -> Data
  {
    try encode(snapshot, version: version, canonicalRevision: nil)
  }
  static func encode(
    _ snapshot: DocumentSnapshot, version: Int,
    canonicalRevision: Int64?
  ) throws -> Data {
    let measurement = DocumentInstrumentation.begin(
      "PersistenceEncode", revision: snapshot.revision)
    defer { DocumentInstrumentation.end(measurement) }
    guard version == payloadVersion || version == 3 && snapshot.invocations.isEmpty else {
      throw StoreError.unsupportedVersion
    }
    guard snapshot.utf16Count <= maximumBytes else { throw StoreError.sizeLimit }
    let materialized = try snapshot.validatedMaterialization()
    guard materialized.text.utf8.count <= maximumBytes else { throw StoreError.sizeLimit }
    let payload = Payload(
      snapshot, text: materialized.text, lines: materialized.lines,
      revision: canonicalRevision)
    var canonical = payload
    canonical.invocations = nil
    var envelope = Envelope(
      formatVersion: version, document: payload, checksum: checksum(try encoder().encode(canonical))
    )
    if version >= 4, let annotations = payload.invocations {
      envelope.annotationChecksum = checksum(try encoder().encode(annotations))
    }
    let data = try encoder().encode(envelope)
    guard data.count <= maximumBytes else { throw StoreError.sizeLimit }
    return data
  }
  public static func decode(_ data: Data, reportChecksumMismatch: Bool = false) throws -> (
    snapshot: DocumentSnapshot, version: Int
  ) {
    guard data.count <= maximumBytes else { throw StoreError.sizeLimit }
    do {
      let decoder = JSONDecoder(), header = try JSONDecoder().decode(Header.self, from: data)
      let version = header.formatVersion ?? header.schemaVersion ?? 0
      guard version <= payloadVersion else { throw StoreError.unsupportedVersion }
      let snapshot: DocumentSnapshot
      switch version {
      case 1:
        let old = try decoder.decode(LegacyV1.self, from: data)
        snapshot = DocumentSnapshot(text: old.text, revision: old.revision, lines: old.lines)
      case 2:
        let value = try decoder.decode(LegacyEnvelope.self, from: data).document
        let ids = Set(value.lines.map(\.id))
        let landmarks = (value.landmarks ?? []).map {
          Landmark(
            id: $0.id, lineID: $0.lineID, emoji: $0.emoji, detached: !ids.contains($0.lineID))
        }
        snapshot = DocumentSnapshot(
          documentID: value.id, text: value.content, revision: value.liveRevision,
          lines: value.lines, landmarks: landmarks)
      case 3, 4:
        let envelope = try decoder.decode(Envelope.self, from: data)
        let value = envelope.document
        var canonical = value
        canonical.invocations = nil
        guard
          envelope.checksum == checksum(try encoder().encode(canonical))
        else {
          throw reportChecksumMismatch ? StoreError.checksumMismatch : StoreError.invalidPayload
        }
        let stored = value.invocations ?? []
        let annotationHash = checksum(try encoder().encode(stored))
        let metadataValid =
          version >= 4 && stored.count <= 1000 && envelope.annotationChecksum == annotationHash
        var decoded = DocumentSnapshot(
          documentID: value.id, text: value.content, revision: value.liveRevision,
          lines: value.lines, landmarks: value.landmarks,
          invocations: metadataValid ? stored : [])
        if metadataValid {
          let annotations = ToolInvocation.sanitized(stored, in: decoded).map { value in
            guard value.phase == .inputting, value.message != nil else { return value }
            var normalized = value
            normalized.message = nil
            return normalized
          }
          if annotations != stored {
            decoded = DocumentSnapshot(
              documentID: value.id, text: value.content, revision: value.liveRevision,
              lines: value.lines, landmarks: value.landmarks, invocations: annotations)
          }
        }
        snapshot = decoded
      default: throw StoreError.invalidPayload
      }
      try snapshot.validate()
      return (snapshot, version)
    } catch let error as StoreError { throw error } catch { throw StoreError.invalidPayload }
  }
}
