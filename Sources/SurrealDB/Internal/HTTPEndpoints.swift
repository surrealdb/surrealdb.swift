import Foundation

/// The server's plain HTTP routes (`/health`, `/import`, `/export`), which
/// both transports reach over HTTP. `baseURL` is the server root: the RPC
/// endpoint without `/rpc`, with `ws`/`wss` mapped to `http`/`https`.
struct HTTPEndpoints: Sendable {
    let baseURL: URL
    let timeout: TimeInterval
    let urlSession: URLSession

    init(rpcURL: URL, timeout: TimeInterval, urlSession: URLSession = .shared) {
        var components = URLComponents(url: Endpoint.asHTTP(rpcURL), resolvingAgainstBaseURL: false)
        if var path = components?.path, path.hasSuffix("/rpc") {
            path.removeLast(4)
            components?.path = path
        }
        self.baseURL = components?.url ?? Endpoint.asHTTP(rpcURL)
        self.timeout = timeout
        self.urlSession = urlSession
    }

    func health() async throws {
        _ = try await request("health", method: "GET")
    }

    /// Sends a request to `path` under the base URL and returns the body,
    /// throwing `httpError` for anything but a 2xx response.
    func request(
        _ path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        accept: String? = nil,
        session: SessionContext? = nil
    ) async throws -> Data {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        urlRequest.httpMethod = method
        urlRequest.httpBody = body
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let accept {
            urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let session {
            if let namespace = session.namespace {
                urlRequest.setValue(namespace, forHTTPHeaderField: "Surreal-NS")
            }
            if let database = session.database {
                urlRequest.setValue(database, forHTTPHeaderField: "Surreal-DB")
            }
            if let token = session.accessToken {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw SurrealError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw SurrealError.connectionLost(cause: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SurrealError.invalidResponse("Expected an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SurrealError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
