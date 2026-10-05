import Foundation

/// Output of on-device analysis. Only `tags` and `sentiment` are synced; `text` stays local.
struct MediaAnalysis {
    var tags: [String] = []
    var sentiment: String?        // "positive" | "neutral" | "negative"
    var text: String?             // OCR result / transcript / note body
}
