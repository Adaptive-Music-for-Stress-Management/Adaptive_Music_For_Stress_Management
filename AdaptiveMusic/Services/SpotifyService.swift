import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

struct SpotifyTrack: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let artist: String
    let durationMs: Int
    var artists: [String] = []
    var imageURL: URL? = nil
    var externalURL: URL { URL(string: "https://open.spotify.com/track/\(id)")! }

    static func from(json t: [String: Any]) -> SpotifyTrack? {
        guard let id = t["id"] as? String, let uri = t["uri"] as? String,
              let name = t["name"] as? String, t["is_playable"] as? Bool != false else { return nil }
        let artists = (t["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return SpotifyTrack(id: id, uri: uri, name: name,
                            artist: artists.joined(separator: ", "),
                            durationMs: t["duration_ms"] as? Int ?? 0, artists: artists,
                            imageURL: (((t["album"] as? [String: Any])?["images"] as? [[String: Any]])?.first?["url"] as? String).flatMap { URL(string: $0) })
    }
}

struct SpotifyPlaylist: Identifiable, Equatable {
    let id: String
    let name: String
    let trackCount: Int

    static func from(json value: [String: Any]) -> SpotifyPlaylist? {
        guard let id = value["id"] as? String else { return nil }
        let rawName = (value["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let count = ((value["tracks"] as? [String: Any])?["total"] as? Int) ?? 0
        return SpotifyPlaylist(id: id, name: rawName.isEmpty ? "Untitled playlist" : rawName,
                               trackCount: max(0, count))
    }
}

struct PlaylistTrackCandidate {
    let position: Int
    let track: SpotifyTrack
}

/// Spotify via the Web API only — Authorization-Code-with-PKCE sign-in (no client secret
/// on the device) and playback controlled on the user's own Spotify app through the
/// Connect endpoints. Premium is required for playback control, matching the spec.
@MainActor
final class SpotifyService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    // ⚠️ Fill in your Spotify app's Client ID (Dashboard -> app -> Settings) and add
    //    the redirect URI below to the app's allow-list.
    static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String) ?? ""
    }
    static let redirectURI = "adaptivemusic://spotify-callback"
    static let scopes = "user-read-email user-read-private user-modify-playback-state " +
                        "user-read-playback-state playlist-read-private playlist-read-collaborative"

    @Published var connected = false
    @Published var premium = false
    @Published var product: String? = nil

    private var accessToken: String? { didSet { connected = accessToken != nil } }
    private var refreshToken: String?
    private var expiry = Date.distantPast
    private var verifier = ""
    private var generation = 0
    private var oauthState = ""
    private let network = URLSession(configuration: .ephemeral)
    private var pendingPause: Task<Bool, Never>?
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        let d = UserDefaults.standard
        if let legacy = d.string(forKey: "sp_refresh"), SecretStore.write(legacy, for: "sp_refresh") {
            d.removeObject(forKey: "sp_refresh")
        }
        refreshToken = SecretStore.read("sp_refresh")
        if refreshToken != nil {
            Task { try? await refresh() ; await checkPremium() }
        }
    }

    // MARK: - PKCE sign-in

    func connect() {
        guard !SpotifyService.clientID.isEmpty else { return }
        pendingPause = nil
        verifier = Self.randomString(64)
        oauthState = Self.randomString(32)
        let revision = generation
        let challenge = Self.base64url(SHA256.hash(data: Data(verifier.utf8)))
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: SpotifyService.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: oauthState),
            .init(name: "redirect_uri", value: SpotifyService.redirectURI),
            .init(name: "scope", value: SpotifyService.scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        authSession = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "adaptivemusic") {
            [weak self] url, _ in
            guard let self, let url,
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value else { return }
            Task { @MainActor in
                guard revision == self.generation,
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == self.oauthState else { return }
                await self.exchange(code: code)
            }
        }
        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    private func exchange(code: String) async {
        let revision = generation
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form([
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": SpotifyService.redirectURI,
            "client_id": SpotifyService.clientID, "code_verifier": verifier,
        ])
        guard let (data, _) = try? await network.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else { return }
        guard revision == generation else { return }
        await MainActor.run {
            self.accessToken = access
            self.refreshToken = j["refresh_token"] as? String
            self.expiry = Date().addingTimeInterval(j["expires_in"] as? Double ?? 3600)
            SecretStore.write(self.refreshToken, for: "sp_refresh")
        }
        await checkPremium()
    }

    private func refresh() async throws {
        let revision = generation
        guard let refreshToken else { return }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["grant_type": "refresh_token", "refresh_token": refreshToken,
                                  "client_id": SpotifyService.clientID])
        let (data, _) = try await network.data(for: req)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else { return }
        guard revision == generation else { return }
        await MainActor.run {
            self.accessToken = access
            if let r = j["refresh_token"] as? String {
                self.refreshToken = r
                SecretStore.write(r, for: "sp_refresh")
            }
            self.expiry = Date().addingTimeInterval(j["expires_in"] as? Double ?? 3600)
        }
    }

    private func token() async -> String? {
        if accessToken == nil || Date() > expiry.addingTimeInterval(-30) { try? await refresh() }
        return accessToken
    }

    func disconnect() {
        let oldToken = accessToken
        generation &+= 1
        authSession?.cancel(); authSession = nil
        accessToken = nil; refreshToken = nil; premium = false; product = nil
        expiry = .distantPast; verifier = ""; oauthState = ""
        SecretStore.write(nil, for: "sp_refresh")
        UserDefaults.standard.removeObject(forKey: "sp_refresh")
        network.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        // Captured token is used solely to stop playback, then released.
        pendingPause = Task {
            guard let oldToken else { return true }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/pause")!)
            req.httpMethod = "PUT"; req.timeoutInterval = 8
            req.setValue("Bearer \(oldToken)", forHTTPHeaderField: "Authorization")
            let connection = URLSession(configuration: .ephemeral)
            defer { connection.invalidateAndCancel() }
            guard let (_, response) = try? await connection.data(for: req),
                  let code = (response as? HTTPURLResponse)?.statusCode else { return false }
            return (200...299).contains(code) || code == 404
        }
    }

    // MARK: - Web API

    private func api(_ method: String, _ path: String, query: [String: String] = [:],
                     body: [String: Any]? = nil) async -> (Int, [String: Any]?) {
        let revision = generation
        guard let tok = await token(), revision == generation else { return (401, nil) }
        var comps = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { comps.queryItems = query.map { .init(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await network.data(for: req) else { return (0, nil) }
        guard revision == generation else { return (401, nil) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (code, json)
    }

    @discardableResult
    func checkPremium() async -> Bool {
        let (_, j) = await api("GET", "/me")
        let product = j?["product"] as? String
        await MainActor.run {
            self.product = product
            self.premium = product == "premium"
        }
        return product == "premium"
    }

    /// The device_id of this user's active Spotify app (waking the iPhone app if needed).
    func activeDeviceID() async -> String? {
        for attempt in 0..<2 {
            let (_, j) = await api("GET", "/me/player/devices")
            let devices = j?["devices"] as? [[String: Any]] ?? []
            // prefer an active device, then this phone, then anything
            let active = devices.first { ($0["is_active"] as? Bool) == true }
            let phone = devices.first { ($0["type"] as? String) == "Smartphone" }
            if let d = (active ?? phone ?? devices.first), let id = d["id"] as? String { return id }
            if attempt == 0 {
                await MainActor.run {                      // nudge the Spotify app awake
                    if let url = URL(string: "spotify:"), UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        return nil
    }

    func play(uri: String, deviceID: String?, positionMs: Int = 0) async -> Bool {
        var q: [String: String] = [:]
        if let deviceID { q["device_id"] = deviceID }
        let body: [String: Any] = ["uris": [uri], "position_ms": max(0, positionMs)]
        let (code, _) = await api("PUT", "/me/player/play", query: q, body: body)
        return (200...299).contains(code)
    }

    @discardableResult func pause() async -> Bool {
        if let pendingPause { return await pendingPause.value }
        if accessToken == nil && refreshToken == nil { return true }
        let (code, _) = await api("PUT", "/me/player/pause")
        return (200...299).contains(code) || code == 404
    }
    func resume() async { _ = await api("PUT", "/me/player/play") }
    func seek(ms: Int) async { _ = await api("PUT", "/me/player/seek", query: ["position_ms": String(ms)]) }

    /// (progressMs, durationMs, isPlaying, current track)
    func playerState() async -> (Int, Int, Bool, SpotifyTrack?)? {
        let (code, j) = await api("GET", "/me/player")
        guard code == 200, let j else { return nil }
        let item = j["item"] as? [String: Any]
        return (j["progress_ms"] as? Int ?? 0,
                item?["duration_ms"] as? Int ?? 0,
                j["is_playing"] as? Bool ?? false,
                item.flatMap(SpotifyTrack.from(json:)))
    }

    func searchTrack(_ query: String, limit: Int = 5) async -> [SpotifyTrack] {
        let (_, j) = await api("GET", "/search", query: ["q": query, "type": "track",
                                                         "limit": String(limit), "market": "US"])
        let items = ((j?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.compactMap(SpotifyTrack.from(json:))
    }

    static func matches(artist: String, title: String, track: SpotifyTrack) -> Bool {
        SpotifyTrackMatcher.matches(artist: artist, title: title, actualTitle: track.name,
                                    actualArtists: track.artists.isEmpty ? [track.artist] : track.artists)
    }

    func search(artist: String, title: String) async -> SpotifyTrack? {
        for q in ["track:\"\(title)\" artist:\"\(artist)\"", "\(title) \(artist)"] {
            if let t = await searchTrack(q, limit: 10).first(where: { Self.matches(artist: artist, title: title, track: $0) }) { return t }
        }
        return nil
    }

    /// Fetch playlist names and stable IDs for the picker. Only playlist metadata
    /// is paged here; no playlist track collection is downloaded.
    func playlists() async -> [SpotifyPlaylist] {
        let limit = 50
        var offset = 0
        var result: [SpotifyPlaylist] = []
        var seen: Set<String> = []
        while true {
            let (_, page) = await api("GET", "/me/playlists",
                                      query: ["limit": String(limit), "offset": String(offset)])
            let rows = page?["items"] as? [[String: Any]] ?? []
            for row in rows {
                guard let playlist = SpotifyPlaylist.from(json: row), seen.insert(playlist.id).inserted else {
                    continue
                }
                result.append(playlist)
            }
            guard rows.count == limit else { break }
            offset += rows.count
        }
        return result
    }

    /// Fetch exactly the requested zero-based playlist position for sequential
    /// previous/next playback.
    func playlistTrack(playlistID: String, at position: Int) async -> SpotifyTrack? {
        guard position >= 0 else { return nil }
        let (_, page) = await api("GET", "/playlists/\(playlistID)/tracks",
                                  query: ["limit": "1", "offset": String(position)])
        let rows = page?["items"] as? [[String: Any]] ?? []
        for row in rows {
            guard let value = row["track"] as? [String: Any],
                  (value["is_local"] as? Bool) != true,
                  let track = SpotifyTrack.from(json: value) else { continue }
            return track
        }
        return nil
    }

    /// A bounded real-track sample for stress adaptation. This is the only time
    /// Claude sees playlist songs, and it never requires materialising the list.
    func playlistStressCandidates(playlistID: String, count: Int, around position: Int,
                                  maximum: Int = 25) async -> [PlaylistTrackCandidate] {
        guard count > 0 else { return [] }
        let limit = min(maximum, count)
        let offset = max(0, min(position - limit / 2, count - limit))
        let (_, page) = await api("GET", "/playlists/\(playlistID)/tracks",
                                  query: ["limit": String(limit), "offset": String(offset)])
        let rows = page?["items"] as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { relativePosition, row in
            guard let value = row["track"] as? [String: Any],
                  (value["is_local"] as? Bool) != true,
                  let track = SpotifyTrack.from(json: value) else { return nil }
            return PlaylistTrackCandidate(position: offset + relativePosition, track: track)
        }
    }

    // MARK: - helpers

    private static func form(_ fields: [String: String]) -> Data {
        fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
              .joined(separator: "&").data(using: .utf8)!
    }
    private static func randomString(_ n: Int) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<n).map { _ in chars.randomElement()! })
    }
    private static func base64url<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
