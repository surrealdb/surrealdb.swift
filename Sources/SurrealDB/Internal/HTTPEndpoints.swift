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

    /// Runs a SurrealQL dump (`POST /import`). The server answers 2xx when
    /// every statement applied, and 422 with the failed statements when some
    /// didn't; those still leave the rest of the import in place. Servers
    /// before 3.3.1 answer 200 either way, with any failures in the body.
    func importSQL(_ sql: String, session: SessionContext) async throws {
        let (data, status) = try await send(
            "import",
            method: "POST",
            body: Data(sql.utf8),
            contentType: "text/plain",
            accept: "application/cbor",
            session: session
        )
        switch status {
        case 200..<300:
            guard !data.isEmpty else { return }
            // Anything else here must be the result list; a body we can't
            // read could be hiding failures.
            let rows: [RPCQueryResult]
            do {
                rows = try RPCWire.decodeQueryResults(from: CBORSurrealCodec.decodeValue(data))
            } catch {
                throw SurrealError.invalidResponse("Unexpected /import response: \(error)")
            }
            let failed = rows.filter { $0.status == .err }
            if !failed.isEmpty {
                throw SurrealError.importFailed(failed.enumerated().map { index, row in
                    QueryErrorDetail(index: index, message: row.errorMessage, kind: row.kind, details: row.details)
                })
            }
        case 422:
            let failed = try RPCWire.decodeQueryResults(from: CBORSurrealCodec.decodeValue(data))
            throw SurrealError.importFailed(failed.enumerated().map { index, row in
                QueryErrorDetail(index: index, message: row.errorMessage, kind: row.kind, details: row.details)
            })
        default:
            throw SurrealError.httpError(statusCode: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Exports the database as SurrealQL (`/export`). With no options it's a
    /// `GET`, which exports everything; otherwise the options are posted as
    /// JSON.
    func export(_ options: SurrealExportOptions?, session: SessionContext) async throws -> String {
        let data: Data
        if let options {
            data = try await request(
                "export",
                method: "POST",
                body: try JSONSerialization.data(withJSONObject: options.jsonObject, options: [.sortedKeys]),
                contentType: "application/json",
                session: session
            )
        } else {
            data = try await request("export", method: "GET", session: session)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SurrealError.invalidResponse("The export was not UTF-8 text.")
        }
        return text
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
        let (data, status) = try await send(path, method: method, body: body, contentType: contentType, accept: accept, session: session)
        guard (200..<300).contains(status) else {
            throw SurrealError.httpError(statusCode: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Sends a request and returns the body and status code, whatever the
    /// status.
    func send(
        _ path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        accept: String? = nil,
        session: SessionContext? = nil
    ) async throws -> (Data, Int) {
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
        return (data, http.statusCode)
    }
}
