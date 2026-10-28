import Foundation

enum APIError: LocalizedError {
    case http(Int, String?)
    case server(String)
    case decoding(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return msg ?? "Serverfout (HTTP \(code))."
        case .server(let msg): return msg
        case .decoding(let d): return "Kon antwoord niet lezen: \(d)"
        case .noData: return "Geen gegevens ontvangen."
        }
    }
}

/// Talks to the LINKA consumer backend.
/// Base URL and header names mirror the official app.
struct APIClient {
    static let baseURL = URL(string: "https://app3.linkalock.com")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: Auth-free endpoints

    /// Step 1 of login: ask the backend to e-mail a one-time login code.
    func sendLoginCode(email: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/register_login_send_code"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": email,
            "password": "",
            "platform": auth.platform,
            "device_token": auth.deviceToken,
            "device_name": auth.deviceName,
            "os_version": auth.osVersion,
            "language": auth.language,
            "return_error_if_unregistered": true,
            "profile": ["first_name": "", "last_name": "", "name": ""],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendExpectingStatus(req)
    }

    /// Step 2 of login: exchange the e-mailed code for an auth token.
    func login(email: String, code: String, auth: Identity) async throws -> LoginData {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/login_with_email_code"))
        req.httpMethod = "POST"
        setForm([
            "email": email,
            "email_login_code": code,
            "device_token": auth.deviceToken,
            "platform": auth.platform,
            "device_name": auth.deviceName,
            "os_version": auth.osVersion,
            "language": auth.language,
        ], on: &req)

        let (data, http) = try await rawSend(req)
        try throwIfHTTPError(http, data)
        do {
            let env = try JSONDecoder().decode(APIEnvelope<LoginData>.self, from: data)
            guard env.isSuccess, let payload = env.data else {
                throw APIError.server(env.message ?? "Inloggen mislukt. Klopt de code?")
            }
            return payload
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    // MARK: Authenticated endpoints

    func getLocks(auth: Identity) async throws -> [Lock] {
        // The /api/locks collection requires a Mongo-style `query` param
        // (same pattern the app uses for a single lock: {"serial_no": "..."}).
        // Try a user-scoped filter first, then an empty filter as fallback.
        let userId = auth.userId ?? ""
        let queries = [
            "{}",
            "{\"userProfile_id\":\"\(userId)\"}",
        ]
        var lastError: Error?
        for q in queries {
            do {
                let locks = try await locksQuery(q, auth: auth)
                if !locks.isEmpty { return locks }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return []
    }

    private func locksQuery(_ json: String, auth: Identity) async throws -> [Lock] {
        // NOTE: no trailing slash — "/api/locks/" routes to the single-lock
        // handler that requires serial_no; "/api/locks" is the list handler.
        var comps = URLComponents(string: Self.baseURL.absoluteString + "/api/locks")!
        comps.queryItems = [URLQueryItem(name: "query", value: json)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        authorize(&req, auth: auth)
        return try await decodeArray(req, as: Lock.self)
    }

    func fetchActivities(serial: String, auth: Identity) async throws -> [LockActivity] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/activitys/fetch"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        return try await decodeArray(req, as: LockActivity.self)
    }

    // MARK: - Helpers

    private func authorize(_ req: inout URLRequest, auth: Identity) {
        if let token = auth.authToken { req.setValue(token, forHTTPHeaderField: "x-auth-token") }
        if let uid = auth.userId { req.setValue(uid, forHTTPHeaderField: "x-user-id") }
    }

    private func setForm(_ fields: [String: String], on req: inout URLRequest) {
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = comps.percentEncodedQuery ?? ""
        req.httpBody = Data(encoded.utf8)
    }

    private func rawSend(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        return (data, http)
    }

    private func throwIfHTTPError(_ http: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(APIStatus.self, from: data))?.message
            throw APIError.http(http.statusCode, msg)
        }
    }

    @discardableResult
    private func sendExpectingStatus(_ req: URLRequest) async throws -> APIStatus {
        let (data, http) = try await rawSend(req)
        try throwIfHTTPError(http, data)
        let status = (try? JSONDecoder().decode(APIStatus.self, from: data)) ?? APIStatus(status: "success", message: nil)
        guard status.isSuccess || status.status == nil else {
            throw APIError.server(status.message ?? "Verzoek mislukt.")
        }
        return status
    }

    private func decodeArray<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> [T] {
        let (data, http) = try await rawSend(req)
        try throwIfHTTPError(http, data)
        do {
            let env = try JSONDecoder().decode(APIEnvelope<[T]>.self, from: data)
            guard env.isSuccess else { throw APIError.server(env.message ?? "Verzoek mislukt.") }
            return env.data ?? []
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.decoding("\(error)")
        }
    }
}
