import Foundation

/// On-disk offline cache of plaintext media (protected by iOS Data Protection).
enum MediaStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Copies a file into the store and returns the stored file name.
    static func store(copying source: URL, id: UUID, ext: String) throws -> String {
        let name = "\(id.uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        protect(dest)
        return name
    }

    static func store(data: Data, id: UUID, ext: String) throws -> String {
        let name = "\(id.uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)
        try data.write(to: dest, options: [.atomic, .completeFileProtection])
        return name
    }

    static func remove(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    static func fileExtension(for contentType: String, fallback: String) -> String {
        switch contentType {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/heic": "heic"
        case "video/quicktime": "mov"
        case "video/mp4": "mp4"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/mpeg": "mp3"
        case "text/plain": "txt"
        default: fallback
        }
    }
}
