import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Session expired. Please sign in again."
        case .http(let code, let msg): "Server error \(code): \(msg)"
        case .invalidResponse: "Unexpected server response."
        }
    }
}

enum AppConfig {
    static var baseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://localhost:8000")!
    }
}

/// Talks to the FastAPI service. Adds the JWT, and transparently refreshes it once on a 401.
actor APIClient {
    static let shared = APIClient()

    private let session = URLSession(configuration: .default)
    private let accessAccount = "access-token"
    private let refreshAccount = "refresh-token"

    var hasSession: Bool { KeychainStore.load(account: refreshAccount) != nil }

    // MARK: Auth

    func register(email: String, password: String) async throws { try await authenticate("auth/register", email, password) }
    func login(email: String, password: String) async throws { try await authenticate("auth/login", email, password) }

    func logout() {
        KeychainStore.delete(account: accessAccount)
        KeychainStore.delete(account: refreshAccount)
    }

    private func authenticate(_ path: String, _ email: String, _ password: String) async throws {
        struct Body: Encodable { let email: String; let password: String }
        var req = URLRequest(url: AppConfig.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONCoding.encoder.encode(Body(email: email, password: password))
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        save(try JSONCoding.decoder.decode(TokenPair.self, from: data))
    }

    private func save(_ pair: TokenPair) {
        KeychainStore.save(Data(pair.accessToken.utf8), account: accessAccount)
        KeychainStore.save(Data(pair.refreshToken.utf8), account: refreshAccount)
    }

    private func refreshTokens() async throws {
        guard let data = KeychainStore.load(account: refreshAccount), let token = String(data: data, encoding: .utf8) else {
            throw APIError.unauthorized
        }
        var req = URLRequest(url: AppConfig.baseURL.appendingPathComponent("auth/refresh"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": token])
        let (body, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { logout(); throw APIError.unauthorized }
        save(try JSONCoding.decoder.decode(TokenPair.self, from: body))
    }

    // MARK: Requests

    private func authorized(_ req: URLRequest) -> URLRequest {
        var r = req
        if let d = KeychainStore.load(account: accessAccount), let t = String(data: d, encoding: .utf8) {
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    /// Runs a request, refreshing the token and retrying once if the server answers 401.
    private func perform(_ build: () -> URLRequest, upload file: URL? = nil) async throws -> Data {
        func run() async throws -> (Data, URLResponse) {
            let req = authorized(build())
            if let file { return try await session.upload(for: req, fromFile: file) }
            return try await session.data(for: req)
        }
        var (data, resp) = try await run()
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            try await refreshTokens()
            (data, resp) = try await run()
        }
        try Self.check(resp, data)
        return data
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        default:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw APIError.http(http.statusCode, detail.map { "\($0)" } ?? "")
        }
    }

    // MARK: Assets

    func upsert(id: UUID, _ dto: AssetUpsertDTO) async throws -> AssetDTO {
        let body = try JSONCoding.encoder.encode(dto)
        let data = try await perform {
            var r = URLRequest(url: AppConfig.baseURL.appendingPathComponent("assets/\(id.uuidString.lowercased())"))
            r.httpMethod = "PUT"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }
        return try JSONCoding.decoder.decode(AssetDTO.self, from: data)
    }

    /// Uploads an already-encrypted file as the raw request body.
    func uploadContent(id: UUID, encryptedFile: URL, sha256: String) async throws -> AssetDTO {
        let data = try await perform({
            var r = URLRequest(url: AppConfig.baseURL.appendingPathComponent("assets/\(id.uuidString.lowercased())/content"))
            r.httpMethod = "PUT"
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            r.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
            return r
        }, upload: encryptedFile)
        return try JSONCoding.decoder.decode(AssetDTO.self, from: data)
    }

    func downloadContent(id: UUID) async throws -> Data {
        try await perform {
            URLRequest(url: AppConfig.baseURL.appendingPathComponent("assets/\(id.uuidString.lowercased())/content"))
        }
    }

    func delete(id: UUID) async throws {
        do {
            _ = try await perform {
                var r = URLRequest(url: AppConfig.baseURL.appendingPathComponent("assets/\(id.uuidString.lowercased())"))
                r.httpMethod = "DELETE"
                return r
            }
        } catch APIError.http(404, _) {
            // already gone on the server
        }
    }

    func changes(since: Int, limit: Int = 200) async throws -> SyncResponseDTO {
        let data = try await perform {
            var c = URLComponents(url: AppConfig.baseURL.appendingPathComponent("sync/changes"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "since", value: "\(since)"), .init(name: "limit", value: "\(limit)")]
            return URLRequest(url: c.url!)
        }
        return try JSONCoding.decoder.decode(SyncResponseDTO.self, from: data)
    }
}
