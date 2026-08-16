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

    static func from(json t: [String: Any]) -> SpotifyTrack? {
        guard let id = t["id"] as? String, let uri = t["uri"] as? String,
              let name = t["name"] as? String else { return nil }
        let artists = (t["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return SpotifyTrack(id: id, uri: uri, name: name,
                            artist: artists.joined(separator: ", "),
                            durationMs: t["duration_ms"] as? Int ?? 0)
    }
}

/// Spotify via the Web API only — Authorization-Code-with-PKCE sign-in (no client secret
/// on the device) and playback controlled on the user's own Spotify app through the
/// Connect endpoints. Premium is required for playback control, matching the spec.
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
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        let d = UserDefaults.standard
        refreshToken = d.string(forKey: "sp_refresh")
        if refreshToken != nil {
            Task { try? await refresh() ; await checkPremium() }
        }
    }

    // MARK: - PKCE sign-in

    func connect() {
        guard !SpotifyService.clientID.isEmpty else { return }
        verifier = Self.randomString(64)
        let challenge = Self.base64url(SHA256.hash(data: Data(verifier.utf8)))
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: SpotifyService.clientID),
            .init(name: "response_type", value: "code"),
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
            Task { await self.exchange(code: code) }
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
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form([
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": SpotifyService.redirectURI,
            "client_id": SpotifyService.clientID, "code_verifier": verifier,
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else { return }
        await MainActor.run {
            self.accessToken = access
            self.refreshToken = j["refresh_token"] as? String
            self.expiry = Date().addingTimeInterval(j["expires_in"] as? Double ?? 3600)
            UserDefaults.standard.set(self.refreshToken, forKey: "sp_refresh")
        }
        await checkPremium()
    }

    private func refresh() async throws {
        guard let refreshToken else { return }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["grant_type": "refresh_token", "refresh_token": refreshToken,
                                  "client_id": SpotifyService.clientID])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else { return }
        await MainActor.run {
            self.accessToken = access
            if let r = j["refresh_token"] as? String {
                self.refreshToken = r
                UserDefaults.standard.set(r, forKey: "sp_refresh")
            }
            self.expiry = Date().addingTimeInterval(j["expires_in"] as? Double ?? 3600)
        }
    }

    private func token() async -> String? {
        if accessToken == nil || Date() > expiry.addingTimeInterval(-30) { try? await refresh() }
        return accessToken
    }

    func disconnect() {
        accessToken = nil; refreshToken = nil; premium = false; product = nil
        UserDefaults.standard.removeObject(forKey: "sp_refresh")
    }

    // MARK: - Web API

    private func api(_ method: String, _ path: String, query: [String: String] = [:],
                     body: [String: Any]? = nil) async -> (Int, [String: Any]?) {
        guard let tok = await token() else { return (401, nil) }
        var comps = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { comps.queryItems = query.map { .init(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
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

    func play(uri: String, deviceID: String?) async -> Bool {
        var q: [String: String] = [:]
        if let deviceID { q["device_id"] = deviceID }
        let (code, _) = await api("PUT", "/me/player/play", query: q, body: ["uris": [uri]])
        return (200...299).contains(code)
    }

    func pause() async { _ = await api("PUT", "/me/player/pause") }
    func resume() async { _ = await api("PUT", "/me/player/play") }
    func seek(ms: Int) async { _ = await api("PUT", "/me/player/seek", query: ["position_ms": String(ms)]) }

    /// (progressMs, durationMs, isPlaying, trackID)
    func playerState() async -> (Int, Int, Bool, String?)? {
        let (code, j) = await api("GET", "/me/player")
        guard code == 200, let j else { return nil }
        let item = j["item"] as? [String: Any]
        return (j["progress_ms"] as? Int ?? 0,
                item?["duration_ms"] as? Int ?? 0,
                j["is_playing"] as? Bool ?? false,
                item?["id"] as? String)
    }

    func searchTrack(_ query: String, limit: Int = 5) async -> [SpotifyTrack] {
        let (_, j) = await api("GET", "/search", query: ["q": query, "type": "track",
                                                         "limit": String(limit), "market": "US"])
        let items = ((j?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.compactMap(SpotifyTrack.from(json:))
    }

    func search(artist: String, title: String) async -> SpotifyTrack? {
        for q in ["track:\"\(title)\" artist:\"\(artist)\"", "\(title) \(artist)"] {
            if let t = await searchTrack(q, limit: 5).first { return t }
        }
        return nil
    }

    /// Find the named playlist in the user's library and return its playable tracks.
    func playlistTracks(named name: String) async -> (name: String, tracks: [SpotifyTrack])? {
        let (_, j) = await api("GET", "/me/playlists", query: ["limit": "50"])
        let items = j?["items"] as? [[String: Any]] ?? []
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        let hit = items.first { (($0["name"] as? String) ?? "").lowercased() == lower }
               ?? items.first { (($0["name"] as? String) ?? "").lowercased().contains(lower) }
        guard let hit, let id = hit["id"] as? String else { return nil }
        var tracks: [SpotifyTrack] = []
        var offset = 0
        while tracks.count < 300 {
            let (_, page) = await api("GET", "/playlists/\(id)/tracks",
                                      query: ["limit": "100", "offset": String(offset)])
            let rows = page?["items"] as? [[String: Any]] ?? []
            for row in rows {
                if let t = row["track"] as? [String: Any], (t["is_local"] as? Bool) != true,
                   let track = SpotifyTrack.from(json: t) { tracks.append(track) }
            }
            if rows.count < 100 { break }
            offset += 100
        }
        return tracks.isEmpty ? nil : ((hit["name"] as? String) ?? name, tracks)
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
