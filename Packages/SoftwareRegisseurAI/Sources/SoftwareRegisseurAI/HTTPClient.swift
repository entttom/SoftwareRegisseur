import Foundation

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Injectable transport so tests never touch the network.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Production transport. TLS is enforced by URLSession/ATS (spec I: transport via TLS).
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIProviderError.invalidResponse("Keine HTTP-Antwort")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as AIProviderError {
            throw error
        } catch is CancellationError {
            throw AIProviderError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AIProviderError.timeout
            case .cancelled: throw AIProviderError.cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw AIProviderError.offline
            default:
                throw AIProviderError.network(error.localizedDescription)
            }
        }
    }
}

/// Shared request construction helpers.
enum HTTPRequestBuilder {
    static func jsonRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: JSONValue?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.encoded()
        }
        return request
    }

    static func url(_ base: URL, path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let basePath = components?.path ?? ""
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components?.percentEncodedPath = trimmedBase + path
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw AIProviderError.invalidRequest(String(localized: "Ungültige URL", bundle: .module))
        }
        return url
    }

    /// Percent-encodes a single path segment (model ids may contain `/` or `:`).
    static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#:")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
