import Foundation

enum SupabaseError: Error, Equatable {
    case notConfigured
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)
}

/// Supplies the current user access token (JWT). `AuthService` conforms to this later;
/// when `accessToken` is nil, requests fall back to the public anon key.
protocol TokenProvider: AnyObject {
    var accessToken: String? { get }
    /// Renew the access token if it's stale/expired. Called once before a 401 retry; may clear
    /// the token (signing the client back to the anon key). Defaults to a no-op for plain holders.
    func refreshIfNeeded() async
}

extension TokenProvider {
    func refreshIfNeeded() async {}
}

/// Thin async REST client for Supabase (PostgREST `/rest/v1` + GoTrue `/auth/v1`).
/// No SDK — plain URLSession. Request building is split out as pure functions so it's unit-testable.
final class SupabaseClient {
    let config: SupabaseConfig
    private let session: URLSession
    weak var tokenProvider: TokenProvider?

    init(config: SupabaseConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Returns nil (and the app runs local-only) when no `Supabase.plist` is configured.
    convenience init?(session: URLSession = .shared) {
        guard let config = SupabaseConfig.shared else { return nil }
        self.init(config: config, session: session)
    }

    // MARK: - Request building (pure / testable)

    func restRequest(table: String, method: String = "GET",
                     query: [URLQueryItem] = [], body: Data? = nil,
                     prefer: String? = nil) -> URLRequest {
        var comps = URLComponents(
            url: config.url.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        applyHeaders(&req)
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        return req
    }

    func authRequest(path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var comps = URLComponents(
            url: config.url.appendingPathComponent("auth/v1/\(path)"),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = body == nil ? "GET" : "POST"
        applyHeaders(&req)
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func applyHeaders(_ req: inout URLRequest) {
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(tokenProvider?.accessToken ?? config.anonKey)",
                     forHTTPHeaderField: "Authorization")
    }

    // MARK: - Perform

    /// Sends the request; on a 401 (a stale/expired JWT is rejected even for `using(true)` reads)
    /// it refreshes the token once and retries. If the refresh signs the user out, the retry falls
    /// back to the anon key, so world-readable tables keep loading regardless of auth state.
    @discardableResult
    func perform(_ request: URLRequest) async throws -> Data {
        do {
            return try await send(request)
        } catch SupabaseError.http(401, _) {
            await tokenProvider?.refreshIfNeeded()
            return try await send(reauthorized(request))
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // The caller's Task was cancelled (e.g. SwiftUI tore down a `.refreshable`
            // gesture mid-flight) — not a real connectivity failure, so callers can
            // tell it apart from one and skip surfacing an error to the user.
            throw CancellationError()
        } catch {
            throw SupabaseError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseError.http(status: http.statusCode,
                                     body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Re-stamp the `apikey`/`Authorization` headers (with the now-refreshed token) on an existing
    /// request, preserving its method/body, for a post-refresh retry.
    private func reauthorized(_ request: URLRequest) -> URLRequest {
        var req = request
        applyHeaders(&req)
        return req
    }

    // MARK: - Typed helpers

    func select<T: Decodable>(_ table: String, query: [URLQueryItem] = [],
                              decoder: JSONDecoder = .supabase, as type: T.Type = T.self) async throws -> T {
        let data = try await perform(restRequest(table: table, query: query))
        do { return try decoder.decode(T.self, from: data) }
        catch { throw SupabaseError.decoding(String(describing: error)) }
    }

    /// Plain insert (append). Used for `rating_history`.
    func insert<Body: Encodable>(_ table: String, values: Body) async throws {
        let body = try JSONEncoder.supabase.encode(values)
        try await perform(restRequest(table: table, method: "POST", body: body, prefer: "return=minimal"))
    }

    /// Insert-or-update by primary key / `onConflict` (PostgREST merge-duplicates).
    func upsert<Body: Encodable>(_ table: String, values: Body,
                                 onConflict: String? = nil) async throws {
        let body = try JSONEncoder.supabase.encode(values)
        var query: [URLQueryItem] = []
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }
        let req = restRequest(table: table, method: "POST", query: query, body: body,
                              prefer: "resolution=merge-duplicates,return=minimal")
        try await perform(req)
    }

    /// Calls a Postgres function via PostgREST (`POST /rest/v1/rpc/<fn>`).
    @discardableResult
    func rpc<Args: Encodable>(_ function: String, args: Args) async throws -> Data {
        let body = try JSONEncoder.supabase.encode(args)
        return try await perform(restRequest(table: "rpc/\(function)", method: "POST", body: body))
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder.supabase.decode(T.self, from: data) }
        catch { throw SupabaseError.decoding(String(describing: error)) }
    }

    // MARK: - Auth (GoTrue)

    /// POST `/auth/v1/token?grant_type=...` with a simple JSON body. Returns the raw response data.
    func authToken(grantType: String, body: [String: String]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body)
        let req = authRequest(path: "token",
                              query: [URLQueryItem(name: "grant_type", value: grantType)],
                              body: data)
        return try await perform(req)
    }
}

extension JSONDecoder {
    static let supabase: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let supabase: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
