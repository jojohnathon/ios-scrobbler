import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class LastFMController: ObservableObject {
    @Published var apiKey = ""
    @Published var apiSecret = ""
    @Published private(set) var username: String?
    @Published private(set) var status = "Connect a Last.fm account to submit plays."
    @Published private(set) var authorizing = false

    private var store: ScrobbleStore?
    private var credentials: LastFMCredentials?
    private var pending: PendingAuthorization?
    private var flushing = false
    private var retryTask: Task<Void, Never>?
    private var pausedUntil: Date?

    init() {
        do {
            store = try ScrobbleStore()
            if let saved = try LastFMKeychain.load() { activate(saved) }
        } catch {
            status = error.localizedDescription
        }
    }

    func startAuthorization() async -> URL? {
        guard !authorizing, username == nil else { return nil }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else {
            status = "Enter your Last.fm API key and shared secret."
            return nil
        }
        authorizing = true
        pending = nil
        defer { authorizing = false }
        do {
            let token = try await LastFMAPI.token(key: key, secret: secret)
            var browserURL = URLComponents()
            browserURL.scheme = "https"
            browserURL.host = "www.last.fm"
            browserURL.path = "/api/auth/"
            browserURL.percentEncodedQuery = LastFMAPI.encodeForm(["api_key": key, "token": token])
            pending = PendingAuthorization(apiKey: key, apiSecret: secret, token: token)
            status = "Approve access in the browser, then tap Finish Authorization."
            return browserURL.url
        } catch {
            status = "Authorization failed. \(error.localizedDescription)"
            return nil
        }
    }

    func finishAuthorization() async {
        guard !authorizing else { return }
        guard let pending else {
            status = "Start authorization and approve access in the browser first."
            return
        }
        authorizing = true
        defer { authorizing = false }
        do {
            let session = try await LastFMAPI.session(for: pending)
            let saved = LastFMCredentials(apiKey: pending.apiKey, apiSecret: pending.apiSecret, session: session)
            try LastFMKeychain.save(saved)
            self.pending = nil
            activate(saved)
            do { try store?.bindUnassigned(to: saved.session.name) }
            catch { status = "Could not assign saved plays. \(error.localizedDescription)" }
            scheduleRetry(at: Date())
        } catch {
            status = "Could not finish authorization. \(error.localizedDescription)"
        }
    }

    func signOut() {
        guard !authorizing else { return }
        do {
            try LastFMKeychain.delete()
            disconnect()
            pending = nil
            status = "Last.fm disconnected."
        } catch {
            status = error.localizedDescription
        }
    }

    func nowPlaying(_ track: RecognizedTrack) async {
        guard let credentials else { return }
        do {
            try await LastFMAPI.nowPlaying(track, credentials: credentials)
        } catch {
            guard self.credentials == credentials else { return }
            handleSessionError(error, credentials: credentials)
            if self.credentials != nil { status = "Could not update Now Playing. \(error.localizedDescription)" }
        }
    }

    @discardableResult
    func submit(_ track: RecognizedTrack, startedAt: Date, playID: UUID) async -> Bool {
        guard let store else {
            status = "The local scrobble queue could not be opened."
            return false
        }
        do {
            try store.enqueue(track, startedAt: startedAt, id: playID, account: username)
        } catch {
            status = "Could not save this play. \(error.localizedDescription)"
            return false
        }
        if username == nil { status = "Play saved. Connect Last.fm to send it." }
        else if !flushing { scheduleRetry(at: pausedUntil ?? Date()) }
        return true
    }

    func retryPending() async {
        guard let credentials, let store, !flushing else { return }
        if let pausedUntil, pausedUntil > Date() {
            scheduleRetry(at: pausedUntil)
            return
        }
        retryTask?.cancel()
        retryTask = nil
        flushing = true
        defer {
            flushing = false
            if let current = self.credentials, current != credentials { scheduleRetry(at: Date()) }
        }
        do {
            try store.bindUnassigned(to: credentials.session.name)
            while !Task.isCancelled, self.credentials == credentials,
                  let play = try store.nextPlay(for: credentials.session.name) {
                let retryDelay = 15 * pow(2, Double(min(play.attempts, 6)))
                guard try await deliver(play, using: store, credentials: credentials, retryDelay: retryDelay) else { return }
            }
            if self.credentials == credentials, let next = try store.nextRetry(for: credentials.session.name) {
                scheduleRetry(at: next)
            }
        } catch {
            status = "Could not process the scrobble queue. \(error.localizedDescription)"
        }
    }

    private func deliver(
        _ play: OutboxPlay, using store: ScrobbleStore, credentials: LastFMCredentials, retryDelay: TimeInterval
    ) async throws -> Bool {
        try store.markAttempt(play, retryAfter: Date().addingTimeInterval(retryDelay))
        let outcome: String
        var submitted = false
        do {
            if play.needsReconciliation, try await LastFMAPI.alreadySubmitted(play, credentials: credentials) {
                outcome = "accepted"
            } else {
                guard self.credentials == credentials, !Task.isCancelled else { return false }
                submitted = true
                outcome = try await LastFMAPI.scrobble(play, credentials: credentials) ? "accepted" : "ignored"
            }
        } catch {
            guard self.credentials == credentials else { return false }
            if handleSessionError(error, credentials: credentials) { return false }
            if submitted, let apiError = error as? LastFMError, apiError.isPermanentRejection {
                try store.finish(play, outcome: "rejected")
                status = "Last.fm rejected \(play.title). \(error.localizedDescription)"
                return true
            }
            let retryAt = Date().addingTimeInterval(retryDelay)
            try store.deferRetry(play, until: retryAt)
            status = "Play queued for retry. \(error.localizedDescription)"
            pausedUntil = retryAt
            scheduleRetry(at: retryAt)
            return false
        }
        try store.finish(play, outcome: outcome)
        if self.credentials == credentials {
            status = outcome == "accepted" ? "Scrobbled \(play.title)." : "Last.fm ignored \(play.title)."
        }
        return true
    }

    private func activate(_ saved: LastFMCredentials) {
        credentials = saved
        username = saved.session.name
        apiKey = saved.apiKey
        apiSecret = saved.apiSecret
        status = "Connected as \(saved.session.name)."
    }

    private func disconnect() {
        credentials = nil
        username = nil
        retryTask?.cancel()
        retryTask = nil
        pausedUntil = nil
    }

    @discardableResult
    private func handleSessionError(_ error: Error, credentials: LastFMCredentials) -> Bool {
        guard let apiError = error as? LastFMError, case .api(9, _) = apiError,
              self.credentials == credentials else { return false }
        try? LastFMKeychain.delete()
        disconnect()
        status = "The Last.fm session expired. Reconnect to send queued plays."
        return true
    }

    private func scheduleRetry(at date: Date) {
        retryTask?.cancel()
        let delay = max(1, date.timeIntervalSinceNow)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            await self.retryPending()
        }
    }
}

private struct PendingAuthorization: Sendable {
    let apiKey: String
    let apiSecret: String
    let token: String
}

private struct LastFMSession: Codable, Equatable, Sendable {
    let name: String
    let key: String
}

private struct LastFMCredentials: Codable, Equatable, Sendable {
    let apiKey: String
    let apiSecret: String
    let session: LastFMSession
}

private enum LastFMKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "scrobbler").lastfm",
         kSecAttrAccount as String: "credentials"]
    }

    static func load() throws -> LastFMCredentials? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(attributes as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw LastFMError.keychain(result) }
        return try JSONDecoder().decode(LastFMCredentials.self, from: data)
    }

    static func save(_ credentials: LastFMCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw LastFMError.keychain(update) }
        let insert = SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil)
        guard insert == errSecSuccess else { throw LastFMError.keychain(insert) }
    }

    static func delete() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw LastFMError.keychain(result) }
    }
}

private enum LastFMError: LocalizedError {
    case api(Int, String), http(Int), keychain(OSStatus), invalidResponse

    var errorDescription: String? {
        switch self {
        case .api(let code, let message): return "\(message) (Last.fm error \(code))."
        case .http(let status): return "Last.fm returned HTTP \(status)."
        case .keychain(let status): return "Could not access Last.fm credentials in Keychain (\(status))."
        case .invalidResponse: return "Last.fm returned an unexpected response."
        }
    }

    var isPermanentRejection: Bool {
        switch self {
        case .api(let code, _): return [2, 3, 5, 6, 7].contains(code)
        case .http(let status): return status == 400 || status == 404 || status == 422
        default: return false
        }
    }
}

private enum LastFMAPI {
    private static let httpSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func token(key: String, secret: String) async throws -> String {
        struct Response: Decodable, Sendable { let token: String }
        let response: Response = try await request(method: "auth.getToken", key: key, secret: secret)
        guard !response.token.isEmpty else { throw LastFMError.invalidResponse }
        return response.token
    }

    static func session(for authorization: PendingAuthorization) async throws -> LastFMSession {
        struct Response: Decodable, Sendable { let session: LastFMSession }
        let response: Response = try await request(
            method: "auth.getSession", key: authorization.apiKey, secret: authorization.apiSecret,
            parameters: ["token": authorization.token]
        )
        guard !response.session.name.isEmpty, !response.session.key.isEmpty else { throw LastFMError.invalidResponse }
        return response.session
    }

    static func nowPlaying(_ track: RecognizedTrack, credentials: LastFMCredentials) async throws {
        struct Response: Decodable, Sendable {
            struct NowPlaying: Decodable, Sendable {
                struct IgnoredMessage: Decodable, Sendable { let code: FlexibleInt }
                let ignoredMessage: IgnoredMessage
            }
            let nowplaying: NowPlaying
        }
        let response: Response = try await request(
            method: "track.updateNowPlaying", key: credentials.apiKey, secret: credentials.apiSecret,
            parameters: trackParameters(artist: track.artist, title: track.title, duration: track.durationSeconds)
                .merging(["sk": credentials.session.key]) { _, new in new }, post: true
        )
        guard response.nowplaying.ignoredMessage.code.value == 0 else {
            throw LastFMError.api(response.nowplaying.ignoredMessage.code.value, "Now Playing was ignored")
        }
    }

    static func scrobble(_ play: OutboxPlay, credentials: LastFMCredentials) async throws -> Bool {
        struct Response: Decodable, Sendable {
            struct Scrobbles: Decodable, Sendable {
                struct Counts: Decodable, Sendable { let accepted: FlexibleInt; let ignored: FlexibleInt }
                let counts: Counts
                enum CodingKeys: String, CodingKey { case counts = "@attr" }
            }
            let scrobbles: Scrobbles
        }
        var parameters = trackParameters(artist: play.artist, title: play.title, duration: play.durationSeconds)
        parameters["sk"] = credentials.session.key
        parameters["timestamp"] = String(play.timestamp)
        let response: Response = try await request(
            method: "track.scrobble", key: credentials.apiKey, secret: credentials.apiSecret,
            parameters: parameters, post: true
        )
        let counts = response.scrobbles.counts
        switch (counts.accepted.value, counts.ignored.value) {
        case (1, 0): return true
        case (0, 1): return false
        default: throw LastFMError.invalidResponse
        }
    }

    static func alreadySubmitted(_ play: OutboxPlay, credentials: LastFMCredentials) async throws -> Bool {
        struct Response: Decodable, Sendable {
            struct RecentTracks: Decodable, Sendable {
                struct Track: Decodable, Sendable {
                    struct Artist: Decodable, Sendable {
                        let name: String
                        enum CodingKeys: String, CodingKey { case name = "#text" }
                    }
                    struct Timestamp: Decodable, Sendable { let uts: String }
                    let artist: Artist
                    let name: String
                    let date: Timestamp?
                }
                let track: [Track]
            }
            let recenttracks: RecentTracks
        }
        let response: Response = try await request(
            method: "user.getRecentTracks", key: credentials.apiKey, secret: credentials.apiSecret, parameters: [
                "user": credentials.session.name, "from": String(play.timestamp - 1),
                "to": String(play.timestamp + 1), "limit": "200", "sk": credentials.session.key
            ]
        )
        return response.recenttracks.track.contains { track in
            track.date.flatMap { Int64($0.uts) } == play.timestamp
                && track.name.caseInsensitiveCompare(play.title) == .orderedSame
                && track.artist.name.caseInsensitiveCompare(play.artist) == .orderedSame
        }
    }

    private static func trackParameters(artist: String, title: String, duration: Double?) -> [String: String] {
        var result = ["artist": artist, "track": title]
        if let duration, duration >= 1, duration <= Double(Int32.max) { result["duration"] = String(Int(duration)) }
        return result
    }

    static func encodeForm(_ parameters: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return parameters.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }

    private static func request<Response: Decodable & Sendable>(
        method: String, key: String, secret: String? = nil, parameters: [String: String] = [:], post: Bool = false
    ) async throws -> Response {
        var parameters = parameters
        parameters["method"] = method
        parameters["api_key"] = key
        if let secret {
            let input = parameters.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + secret
            parameters["api_sig"] = Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        parameters["format"] = "json"
        let form = encodeForm(parameters)
        var url = URLComponents()
        url.scheme = "https"
        url.host = "ws.audioscrobbler.com"
        url.path = "/2.0/"
        if !post { url.percentEncodedQuery = form }
        guard let target = url.url else { throw LastFMError.invalidResponse }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if post {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.utf8)
        }
        let (data, response) = try await httpSession.data(for: request)
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(APIErrorBody.self, from: data) {
            throw LastFMError.api(failure.error.value, failure.message)
        }
        guard let http = response as? HTTPURLResponse else { throw LastFMError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw LastFMError.http(http.statusCode) }
        return try decoder.decode(Response.self, from: data)
    }

    private struct APIErrorBody: Decodable {
        let error: FlexibleInt
        let message: String
    }

    private struct FlexibleInt: Decodable, Sendable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) { value = number; return }
            let string = try container.decode(String.self)
            guard let number = Int(string) else { throw LastFMError.invalidResponse }
            value = number
        }
    }
}
