import Foundation
import SwiftData

enum MediaKind: String, Codable, CaseIterable {
    case photo, video, audio, text

    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .text: "doc.text"
        }
    }
}

enum SyncState: String, Codable {
    case pending      // local changes not yet pushed
    case synced
    case pendingDelete
}

/// Local (offline-first) record. Plaintext media lives on disk under `MediaStore`; only the
/// AES-GCM encrypted bytes are ever uploaded.
@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var filename: String
    var contentType: String
    var tags: [String]
    var sentimentRaw: String?
    var extractedText: String?          // OCR / transcript, kept on device only
    var createdAt: Date
    var localFilename: String?          // nil => remote-only, downloaded on demand
    var remoteUploaded: Bool
    var syncStateRaw: String
    var serverRev: Int
    var size: Int

    init(id: UUID = UUID(), kind: MediaKind, filename: String, contentType: String,
         tags: [String] = [], sentiment: String? = nil, extractedText: String? = nil,
         createdAt: Date = .now, localFilename: String? = nil, size: Int = 0) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.filename = filename
        self.contentType = contentType
        self.tags = tags
        self.sentimentRaw = sentiment
        self.extractedText = extractedText
        self.createdAt = createdAt
        self.localFilename = localFilename
        self.remoteUploaded = false
        self.syncStateRaw = SyncState.pending.rawValue
        self.serverRev = 0
        self.size = size
    }

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .photo }
    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pending }
        set { syncStateRaw = newValue.rawValue }
    }
    var localURL: URL? { localFilename.map { MediaStore.directory.appendingPathComponent($0) } }
    var isAvailableOffline: Bool {
        guard let url = localURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
