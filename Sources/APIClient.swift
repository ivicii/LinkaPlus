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
        case .decoding: return "Onverwacht antwoord van de server."
        case .noData: return "Geen gegevens ontvangen."
        }
    }
}

/// Talks to the LINKA consumer backend.
/// Base URL and header names mirror the official app.
struct APIClient {
    static let baseURL = URL(string: "https://app3.linkalock.com")!

    /// One session for the whole app: views create an `APIClient()` on every body
    /// pass, and a URLSession per instance is never released (and reuses nothing).
    private static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        // Fail fast when there is no network: with waitsForConnectivity a request
        // waits (up to days) for a connection, so the offline fall-backs — cached
        // lock list, cached Bluetooth key — would never kick in.
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.shared }

    init() {}

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

    /// The user's lock list. Confirmed via on-device diagnostics: the list
    /// comes from `associated_locks` (user-scoped), which also carries the
    /// GPS `location` [lng, lat]. We then enrich each lock's locked state from
    /// the single-lock endpoint.
    func getLocks(auth: Identity) async throws -> [Lock] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/associated_locks"))
        req.httpMethod = "PUT"
        setForm(["device_token": auth.deviceToken], on: &req)
        authorize(&req, auth: auth)

        let assoc = try await decodeArray(req, as: AssociatedLock.self)
        var locks = assoc.map { $0.asLock() }

        // Best-effort: enrich locked-state (and fall back coords) per serial.
        // In parallel: one slow lookup must not hold up the whole list.
        let serials = locks.map { $0.serial_no }
        let singles = await withTaskGroup(of: (Int, Lock?).self) { group -> [Int: Lock] in
            for (i, serial) in serials.enumerated() {
                guard let serial else { continue }
                group.addTask { (i, try? await self.lockSingle(serial: serial, auth: auth)) }
            }
            var out: [Int: Lock] = [:]
            for await (i, single) in group { if let single { out[i] = single } }
            return out
        }
        for (i, single) in singles { locks[i] = locks[i].merging(single) }
        return locks
    }

    /// Single-lock lookup by serial (the `/api/locks?query={"serial_no":...}` route).
    func lockSingle(serial: String, auth: Identity) async throws -> Lock? {
        var comps = URLComponents(string: Self.baseURL.absoluteString + "/api/locks")!
        comps.queryItems = [URLQueryItem(name: "query", value: "{\"serial_no\":\"\(serial)\"}")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        authorize(&req, auth: auth)
        return try await decodeArray(req, as: Lock.self).first
    }

    /// Start/stop recovery (theft-tracking) mode. When on, the lock reports
    /// live GPS and `currentTracking` returns the route.
    func setRecoveryMode(serial: String, enabled: Bool, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/leo/recovery_mode"))
        req.httpMethod = "POST"
        setForm(["lock_serial_no": serial, "recovery_mode": enabled ? "true" : "false"], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// Whether a tracking/recovery session is currently active on the server.
    func currentActive(serial: String, auth: Identity) async throws -> Bool {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/leo/current_active"))
        req.httpMethod = "POST"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        let (data, http) = try await rawSend(req)
        try throwIfHTTPError(http, data)
        // Any success envelope with data present → active.
        if let env = try? JSONDecoder().decode(APIEnvelope<CurrentTracking>.self, from: data) {
            return env.isSuccess && ((env.data?.activities?.isEmpty == false) || env.message == nil)
        }
        return false
    }

    /// Live tracking points for the current recovery session. Throws when the
    /// lock is not in tracking mode (server replies "Not currently theft").
    func currentTracking(serial: String, auth: Identity) async throws -> [LockActivity] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/leo/current_tracking"))
        req.httpMethod = "POST"
        setForm(["lock_serial_no": serial, "date": "1970-01-01T00:00:00.000+0000"], on: &req)
        authorize(&req, auth: auth)
        let (data, http) = try await rawSend(req)
        try throwIfHTTPError(http, data)
        let env = try JSONDecoder().decode(APIEnvelope<CurrentTracking>.self, from: data)
        guard env.isSuccess else { throw APIError.server(env.message ?? "Geen tracking.") }
        return env.data?.activities ?? []
    }

    // MARK: Data-plan renewal (Stripe)

    func getPaymentInfo(auth: Identity) async throws -> PaymentInfo {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/payments_consumer/stripe/get_payment_info"))
        req.httpMethod = "POST"
        authorize(&req, auth: auth)
        return try await decodeObject(req, as: PaymentInfo.self)
    }

    /// Create the Stripe customer (must exist before a SetupIntent).
    func addCustomer(auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/payments_consumer/stripe/add_customer"))
        req.httpMethod = "POST"
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// Sync the saved card to the backend (after the PaymentSheet succeeds).
    func addCard(auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/payments_consumer/stripe/update_payment_methods"))
        req.httpMethod = "POST"
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    func getCards(auth: Identity) async throws -> [SavedCard] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/payments_consumer/stripe/get_cards"))
        req.httpMethod = "POST"
        authorize(&req, auth: auth)
        return try await decodeArray(req, as: SavedCard.self)
    }

    func createSetupIntent(auth: Identity) async throws -> SetupIntentData {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/payments_consumer/stripe/create_setup_intent"))
        req.httpMethod = "POST"
        authorize(&req, auth: auth)
        return try await decodeObject(req, as: SetupIntentData.self)
    }

    func enableDataPlan(serial: String, enabled: Bool, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/payments_consumer/stripe/enable_data_plan"))
        req.httpMethod = "POST"
        setForm(["lock_serial_no": serial, "enabled": enabled ? "true" : "false"], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// SIM / data-plan status. This is the same call the official app makes
    /// routinely on its main screen to read usage (it returns status; billing
    /// is a separate Stripe flow). Needs a location (phone or lock).
    func simStatus(serial: String, lat: Double, lng: Double, auth: Identity) async throws -> SimStatus {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/leo/activate_sim_consumer"))
        req.httpMethod = "POST"
        setForm(["lock_serial_no": serial, "latitude": String(lat), "longitude": String(lng)], on: &req)
        authorize(&req, auth: auth)
        let (data, http) = try await rawSend(req)
        try throwIfHTTPError(http, data)
        let env = try JSONDecoder().decode(APIEnvelope<SimStatus>.self, from: data)
        guard env.isSuccess, let d = env.data else { throw APIError.server(env.message ?? "Geen SIM-status.") }
        return d
    }

    /// Play the lock's siren so you can locate it (LEO cellular feature).
    func activateSiren(serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/leo/activate_siren"))
        req.httpMethod = "POST"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    // MARK: Sharing & management

    func lockPermissions(serial: String, auth: Identity) async throws -> [LockPermission] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/lock_permissions"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        return try await decodeArray(req, as: LockPermission.self)
    }

    func sendInvite(email: String, serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/send_invite"))
        req.httpMethod = "PUT"
        setForm(["email": email, "lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    func revokeAccess(userId: String, serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/revoke_access"))
        req.httpMethod = "PUT"
        setForm(["userId": userId, "lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// Transfer ownership to another LINKA account (official: PUT /api/keys/transfer_ownership).
    func transferOwnership(email: String, serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/transfer_ownership"))
        req.httpMethod = "PUT"
        setForm(["email": email, "lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// Hide the lock from this account's list (official "Remove device from this phone" for admins).
    func hideLock(serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/hide_lock"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// Remove the lock from the account on the server (official RevocationControllerV2.d()).
    func resetAllLockInformation(serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/reset_all_lock_information_and_keys"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial, "device_token": auth.deviceToken, "api_version": "1"], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    // MARK: Pairing (official LinkaAccessKey flow)

    /// POST /api/locks (upsert_lock) — register the lock object.
    func upsertLock(name: String, serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/locks"))
        req.httpMethod = "POST"
        setForm(["name": name, "serial_no": serial, "is_locked": "false", "lock_type": "leo2"], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// PUT /api/keys/gen_master_key — server mints the master keys to install.
    func genMasterKey(serial: String, auth: Identity) async throws -> GenMasterKey {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/gen_master_key"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        return try await decodeObject(req, as: GenMasterKey.self)
    }

    /// PUT /api/keys/register_lock_with_master_keys — returns the per-user keys.
    func registerLockWithMasterKeys(serial: String, master: String, master2: String, auth: Identity) async throws -> AccessKeys {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/register_lock_with_master_keys"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial, "access_key_master": master, "access_key_master_2": master2,
                 "device_token": auth.deviceToken, "device_app_name": "iOS"], on: &req)
        authorize(&req, auth: auth)
        return try await decodeObject(req, as: AccessKeys.self)
    }

    /// PUT /api/keys/request_for_user_permission_v2 — ask the owner for access.
    func requestUserPermission(serial: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/request_for_user_permission_v2"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    func renameLock(name: String, serial: String, isLocked: Bool, lockType: String, auth: Identity) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/locks"))
        req.httpMethod = "POST"
        setForm(["name": name, "serial_no": serial, "is_locked": isLocked ? "true" : "false", "lock_type": lockType], on: &req)
        authorize(&req, auth: auth)
        _ = try await sendExpectingStatus(req)
    }

    /// Fetch the user's access keys for this lock (for BLE command encryption).
    func checkKeyStatus(serial: String, auth: Identity) async throws -> KeyStatus {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/keys/check_key_status_for_user_v2"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial, "device_token": auth.deviceToken], on: &req)
        authorize(&req, auth: auth)
        return try await decodeObject(req, as: KeyStatus.self)
    }

    func fetchActivities(serial: String, auth: Identity) async throws -> [LockActivity] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/api/activitys/fetch"))
        req.httpMethod = "PUT"
        setForm(["lock_serial_no": serial], on: &req)
        authorize(&req, auth: auth)
        return try await decodeArray(req, as: LockActivity.self)
    }

    // MARK: - Firmware

    /// The firmware image the official app would download for the LEO2 / Lasso.
    func consumerAppVersion(auth: Identity) async throws -> ConsumerAppVersion {
        let url = Self.baseURL.appendingPathComponent("/api/consumer_app_version")
        var lastError: Error = APIError.noData
        // The retrofit verb isn't exposed in the APK; try the common ones.
        for method in ["POST", "PUT", "GET"] {
            var req = URLRequest(url: url)
            req.httpMethod = method
            if method != "GET" { setForm([:], on: &req) }
            authorize(&req, auth: auth)
            do {
                return try await decodeObject(req, as: ConsumerAppVersion.self)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Download a file (e.g. the firmware .zip) to a temporary local file.
    func downloadFile(from urlString: String, suggestedName: String) async throws -> URL {
        guard let url = URL(string: urlString) else { throw APIError.server("Ongeldige firmware-URL.") }
        let (tmp, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, "Download mislukt.")
        }
        let name = suggestedName.isEmpty ? "firmware.zip" : suggestedName
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Diagnostics

    struct ProbeResult: Identifiable {
        let id = UUID()
        let label: String
        let line: String
    }

    /// Fire a raw request and return a compact status + body preview, never throwing.
    func probe(label: String, method: String, path: String,
               query: [String: String] = [:], form: [String: String]? = nil,
               auth: Identity) async -> ProbeResult {
        var comps = URLComponents(string: Self.baseURL.absoluteString + path)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            return ProbeResult(label: label, line: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let form = form { setForm(form, on: &req) }
        authorize(&req, auth: auth)
        do {
            let (data, http) = try await rawSend(req)
            var body = String(data: data, encoding: .utf8) ?? "<binary>"
            body = body.replacingOccurrences(of: "\n", with: " ")
            if body.count > 400 { body = String(body.prefix(400)) + "…" }
            return ProbeResult(label: label, line: "HTTP \(http.statusCode) — \(body)")
        } catch {
            return ProbeResult(label: label, line: "ERR \(error)")
        }
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
        // URLComponents leaves "+" as is, but in a form body "+" means a space —
        // "naam+tag@x.nl" would arrive as "naam tag@x.nl".
        let encoded = (comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
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

    private func decodeObject<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, http) = try await rawSend(req)
        try throwIfHTTPError(http, data)
        do {
            let env = try JSONDecoder().decode(APIEnvelope<T>.self, from: data)
            guard env.isSuccess, let payload = env.data else {
                throw APIError.server(env.message ?? "Verzoek mislukt.")
            }
            return payload
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.decoding("\(error)")
        }
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
