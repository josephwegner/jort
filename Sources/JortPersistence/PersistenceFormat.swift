import Foundation
import JortDocument

public enum StoreError: Error, Equatable, Sendable {
    case sqlite(Int32, String)
    case unsupportedVersion, malformedSchema, invalidPayload, sizeLimit, ownership, io(String), injected(String)
    public var recoverableCorruption: Bool {
        switch self { case .sqlite(let code, _): return code == 11 || code == 26
        case .invalidPayload: return true
        default: return false }
    }
}
public enum PersistenceFormat {
    public static let sqliteVersion = 2
    public static let payloadVersion = 2
    public static let maximumBytes = 64 * 1024 * 1024
    private struct Header: Decodable { let formatVersion: Int?; let schemaVersion: Int? }
    private struct LegacyV1: Decodable {
        let schemaVersion: Int
        let text: String
        let revision: Int64
        let lines: [LineMeta]
    }
    private struct Envelope: Codable {
        let formatVersion: Int
        let document: Payload
    }
    private struct Payload: Codable {
        let id: UUID
        let content: String
        let liveRevision: Int64
        let lines: [LineMeta]
        let landmarks: [Landmark]
        enum CodingKeys: String, CodingKey { case id, content, liveRevision, lines, landmarks }
        init(_ snapshot: DocumentSnapshot) {
            id = snapshot.documentID; content = snapshot.text; liveRevision = snapshot.revision
            lines = snapshot.lines; landmarks = snapshot.landmarks
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            content = try values.decode(String.self, forKey: .content)
            liveRevision = try values.decode(Int64.self, forKey: .liveRevision)
            lines = try values.decode([LineMeta].self, forKey: .lines)
            landmarks = try values.decodeIfPresent([Landmark].self, forKey: .landmarks) ?? []
        }
    }
    public static func encode(_ snapshot: DocumentSnapshot) throws -> Data {
        guard snapshot.text.utf8.count <= maximumBytes else { throw StoreError.sizeLimit }
        try snapshot.validate()
        let data = try JSONEncoder().encode(Envelope(formatVersion: payloadVersion, document: Payload(snapshot)))
        guard data.count <= maximumBytes else { throw StoreError.sizeLimit }
        return data
    }
    public static func decode(_ data: Data) throws -> (snapshot: DocumentSnapshot, version: Int) {
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
                let value = try decoder.decode(Envelope.self, from: data).document
                snapshot = DocumentSnapshot(documentID: value.id, text: value.content, revision: value.liveRevision, lines: value.lines, landmarks: value.landmarks)
            default: throw StoreError.invalidPayload
            }
            try snapshot.validate()
            return (snapshot, version)
        } catch let error as StoreError { throw error }
        catch { throw StoreError.invalidPayload }
    }
}
