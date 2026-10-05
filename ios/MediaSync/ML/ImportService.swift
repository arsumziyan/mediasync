import AVFoundation
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Turns a picked file into a `MediaItem`: copy into the offline store, run on-device ML,
/// persist as `.pending` so the SyncEngine uploads it (encrypted) when the network allows.
@MainActor
enum ImportService {
    @discardableResult
    static func importFile(at source: URL, contentType: UTType?, in context: ModelContext) async throws -> MediaItem {
        let type = contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data
        let kind = Self.kind(for: type)
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "bin") : source.pathExtension.lowercased()

        let stored = try MediaStore.store(copying: source, id: id, ext: ext)
        let localURL = MediaStore.directory.appendingPathComponent(stored)

        let analysis = await analyze(kind: kind, url: localURL)

        let item = MediaItem(
            id: id, kind: kind, filename: source.lastPathComponent,
            contentType: type.preferredMIMEType ?? "application/octet-stream",
            tags: analysis.tags, sentiment: analysis.sentiment, extractedText: analysis.text,
            localFilename: stored,
            size: (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0)
        context.insert(item)
        try context.save()
        return item
    }

    @discardableResult
    static func importImageData(_ data: Data, in context: ModelContext) async throws -> MediaItem {
        let id = UUID()
        let stored = try MediaStore.store(data: data, id: id, ext: "jpg")
        let url = MediaStore.directory.appendingPathComponent(stored)
        let analysis = await ImageAnalyzer.analyze(imageAt: url)
        let item = MediaItem(id: id, kind: .photo, filename: "Photo-\(id.uuidString.prefix(6)).jpg",
                             contentType: "image/jpeg", tags: analysis.tags, sentiment: analysis.sentiment,
                             extractedText: analysis.text, localFilename: stored, size: data.count)
        context.insert(item)
        try context.save()
        return item
    }

    /// Re-runs ML on an existing item (e.g. after a better model ships).
    static func reanalyze(_ item: MediaItem, in context: ModelContext) async {
        guard let url = item.localURL, item.isAvailableOffline else { return }
        let analysis = await analyze(kind: item.kind, url: url)
        item.tags = analysis.tags
        item.sentimentRaw = analysis.sentiment
        item.extractedText = analysis.text
        item.syncState = .pending
        try? context.save()
    }

    private static func analyze(kind: MediaKind, url: URL) async -> MediaAnalysis {
        switch kind {
        case .photo:
            return await ImageAnalyzer.analyze(imageAt: url)
        case .video:
            var a = MediaAnalysis()
            if let frame = await keyFrame(of: url) {
                a = await ImageAnalyzer.analyze(cgImage: frame)
            }
            let audio = await AudioAnalyzer.analyze(fileAt: url)
            a.tags = Array(NSOrderedSet(array: a.tags + audio.tags)) as? [String] ?? a.tags
            a.sentiment = audio.sentiment ?? a.sentiment
            a.text = audio.text ?? a.text
            return a
        case .audio:
            return await AudioAnalyzer.analyze(fileAt: url)
        case .text:
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return MediaAnalysis(tags: SentimentTagger.keywords(in: text), sentiment: SentimentTagger.sentiment(for: text), text: text)
        }
    }

    private static func keyFrame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }

    private static func kind(for type: UTType) -> MediaKind {
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .text
    }
}
