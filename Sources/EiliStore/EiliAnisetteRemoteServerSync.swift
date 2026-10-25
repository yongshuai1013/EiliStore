import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum EiliAnisetteRemoteServerSync {
    enum SyncError: LocalizedError {
        case unsupportedServerURL
        case invalidResponse
        case httpFailure(Int)
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedServerURL: return "目前選用的 Anisette 伺服器網址無效。"
            case .invalidResponse: return "伺服器回應格式無效。"
            case .httpFailure(let status): return "伺服器回應 HTTP 狀態碼 \(status)。"
            case .responseTooLarge: return "伺服器回應超過 64 KiB，已拒絕載入。"
            }
        }
    }

    static func clientInfoEndpoint(for serverURL: URL) throws -> URL {
        guard let scheme = serverURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = serverURL.host, !host.isEmpty,
              serverURL.user == nil, serverURL.password == nil,
              serverURL.query == nil, serverURL.fragment == nil else {
            throw SyncError.unsupportedServerURL
        }
        return serverURL.appendingPathComponent("v3", isDirectory: true)
            .appendingPathComponent("client_info", isDirectory: false)
    }

    static func fetchHeaders(from serverURL: URL, session: URLSession = .shared) async throws -> [String: String] {
        let endpoint = try clientInfoEndpoint(for: serverURL)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard data.count <= 65_536 else { throw SyncError.responseTooLarge }
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw SyncError.httpFailure(response.statusCode) }
        return try decodeHeaders(data)
    }

    static func decodeHeaders(_ data: Data) throws -> [String: String] {
        guard data.count <= 65_536 else { throw SyncError.responseTooLarge }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw SyncError.invalidResponse
        }
        guard let dictionary = object as? [String: Any] else { throw SyncError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in dictionary {
            guard let value = value as? String else { throw SyncError.invalidResponse }
            headers[key] = value
        }
        return headers
    }
}
