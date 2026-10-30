import Foundation

actor HTTPRPCEngine: RPCEngine {
    private let endpoint: URL
    private let urlSession: URLSession
    private let options: SurrealClientOptions
    /// Sends in plain `cbor` until a response arrives as `cbor.2`, then in
    /// `cbor.2` (see `CBORWireCodec`).
    private var codec: any WireCodec
    private var isConnected = false

    init(
        endpoint: URL,
        options: SurrealClientOptions,
        codec: any WireCodec,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = Endpoint.asHTTP(endpoint)
        self.options = options
        self.codec = codec
        self.urlSession = urlSession
    }

    func connect() async throws {
        isConnected = true
    }

    func cborDialect() -> CBORDialect? {
        (codec as? CBORWireCodec)?.dialect
    }

    func close() async {
        isConnected = false
    }

    func send(_ request: RPCRequest, session: SessionContext) async throws -> RPCResponseEnvelope {
        guard isConnected else {
            throw SurrealError.notConnected
        }

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: options.requestTimeout)
        urlRequest.httpMethod = "POST"
        let codec = self.codec
        urlRequest.setValue(codec.httpContentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(codec.httpAccept, forHTTPHeaderField: "Accept")

        if let namespace = session.namespace {
            urlRequest.setValue(namespace, forHTTPHeaderField: "Surreal-NS")
        }
        if let database = session.database {
            urlRequest.setValue(database, forHTTPHeaderField: "Surreal-DB")
        }
        if let token = session.accessToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.httpBody = try codec.encode(request)

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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SurrealError.invalidResponse("Expected HTTPURLResponse.")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SurrealError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let answered = codec.negotiated(httpContentType: httpResponse.value(forHTTPHeaderField: "Content-Type"))
        self.codec = answered
        return try answered.decodeEnvelope(data)
    }
}
