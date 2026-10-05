import Foundation

struct TokenPair: Codable {
    let accessToken: String
    let refreshToken: String
}

struct AssetUpsertDTO: Codable {
    let kind: String
    let filename: String
    let contentType: String
    let tags: [String]
    let sentiment: String?
    let createdAt: Date
}

struct AssetDTO: Codable {
    let id: String
    let kind: String
    let filename: String
    let contentType: String
    let tags: [String]
    let sentiment: String?
    let size: Int
    let sha256: String?
    let uploaded: Bool
    let deleted: Bool
    let rev: Int
    let createdAt: Date
}

struct SyncResponseDTO: Codable {
    let changes: [AssetDTO]
    let cursor: Int
    let hasMore: Bool
}

enum JSONCoding {
    private static func parse(_ s: String) -> Date? {
        // Python emits microseconds ("...45.123456Z"); trim to milliseconds for ISO8601DateFormatter.
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: trimmed) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
            }
            return date
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
