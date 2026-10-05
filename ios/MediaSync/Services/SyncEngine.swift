import Foundation
import SwiftData

/// Offline-first sync: push local changes (metadata first, then encrypted blob), then pull the
/// server's delta feed. Conflict policy: items with unpushed local edits win; otherwise last server
/// revision wins. Runs on its own ModelContext via @ModelActor so it never blocks the UI.
@ModelActor
actor SyncEngine {
    private let cursorKey = "syncCursor"
    private var cursor: Int {
        get { UserDefaults.standard.integer(forKey: cursorKey) }
        set { UserDefaults.standard.set(newValue, forKey: cursorKey) }
    }

    @discardableResult
    func sync() async throws -> Int {
        try await push()
        return try await pull()
    }

    func resetCursor() { cursor = 0 }

    // MARK: Push

    private func push() async throws {
        let pending = try modelContext.fetch(FetchDescriptor<MediaItem>())
            .filter { $0.syncState != .synced || (!$0.remoteUploaded && $0.isAvailableOffline) }

        for item in pending {
            do {
                if item.syncState == .pendingDelete {
                    try await APIClient.shared.delete(id: item.id)
                    MediaStore.remove(item.localFilename)
                    modelContext.delete(item)
                    continue
                }

                let dto = try await APIClient.shared.upsert(id: item.id, AssetUpsertDTO(
                    kind: item.kindRaw, filename: item.filename, contentType: item.contentType,
                    tags: item.tags, sentiment: item.sentimentRaw, createdAt: item.createdAt))
                item.serverRev = dto.rev

                if !dto.uploaded || !item.remoteUploaded, let url = item.localURL, item.isAvailableOffline {
                    let encrypted = try CryptoService.encrypt(try Data(contentsOf: url))
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try encrypted.write(to: tmp)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    let digest = try CryptoService.sha256Hex(of: tmp)
                    let uploaded = try await APIClient.shared.uploadContent(id: item.id, encryptedFile: tmp, sha256: digest)
                    item.remoteUploaded = uploaded.uploaded
                    item.size = uploaded.size
                    item.serverRev = uploaded.rev
                }
                item.syncState = .synced
            } catch APIError.unauthorized {
                throw APIError.unauthorized          // stop; the UI will ask the user to sign in
            } catch {
                continue                             // leave pending; retried on next sync
            }
        }
        try modelContext.save()
    }

    // MARK: Pull

    private func pull() async throws -> Int {
        var applied = 0
        var hasMore = true
        while hasMore {
            let page = try await APIClient.shared.changes(since: cursor)
            for change in page.changes {
                try apply(change)
                applied += 1
            }
            try modelContext.save()
            cursor = page.cursor
            hasMore = page.hasMore
        }
        return applied
    }

    private func apply(_ dto: AssetDTO) throws {
        guard let id = UUID(uuidString: dto.id) else { return }
        let existing = try modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })).first

        if dto.deleted {
            if let existing, existing.syncState != .pending {   // keep unpushed local edits
                MediaStore.remove(existing.localFilename)
                modelContext.delete(existing)
            }
            return
        }

        if let existing {
            guard existing.syncState == .synced else { return }  // local edits win until pushed
            existing.tags = dto.tags
            existing.sentimentRaw = dto.sentiment
            existing.filename = dto.filename
            existing.remoteUploaded = dto.uploaded
            existing.size = dto.size
            existing.serverRev = dto.rev
        } else {
            let item = MediaItem(id: id, kind: MediaKind(rawValue: dto.kind) ?? .photo, filename: dto.filename,
                                 contentType: dto.contentType, tags: dto.tags, sentiment: dto.sentiment,
                                 createdAt: dto.createdAt, localFilename: nil, size: dto.size)
            item.remoteUploaded = dto.uploaded
            item.serverRev = dto.rev
            item.syncState = .synced
            modelContext.insert(item)
        }
    }

    // MARK: On-demand download (remote-only items)

    /// Downloads + decrypts an item's blob into the offline cache and returns the local file name.
    func ensureLocal(_ id: UUID) async throws {
        guard let item = try modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })).first,
              !item.isAvailableOffline, item.remoteUploaded else { return }
        let encrypted = try await APIClient.shared.downloadContent(id: id)
        let plain = try CryptoService.decrypt(encrypted)
        let ext = MediaStore.fileExtension(for: item.contentType, fallback: "bin")
        item.localFilename = try MediaStore.store(data: plain, id: id, ext: ext)
        try modelContext.save()
    }
}
