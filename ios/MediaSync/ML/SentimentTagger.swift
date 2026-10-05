import NaturalLanguage

/// On-device sentiment + keyword extraction using the NaturalLanguage framework.
enum SentimentTagger {
    /// Maps NLTagger's sentiment score (-1...1) to a coarse label.
    static func sentiment(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = trimmed
        let (tag, _) = tagger.tag(at: trimmed.startIndex, unit: .paragraph, scheme: .sentimentScore)
        guard let score = tag.flatMap({ Double($0.rawValue) }) else { return nil }
        switch score {
        case ..<(-0.25): return "negative"
        case 0.25...: return "positive"
        default: return "neutral"
        }
    }

    /// Most frequent nouns as lightweight topic tags.
    static func keywords(in text: String, limit: Int = 5) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var counts: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .noun {
                let word = text[range].lowercased()
                if word.count > 3 { counts[word, default: 0] += 1 }
            }
            return true
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }
}
