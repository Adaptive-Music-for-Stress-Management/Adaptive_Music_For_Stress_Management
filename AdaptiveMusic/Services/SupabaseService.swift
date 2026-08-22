import Foundation
import SwiftUI
import UIKit

struct AdaptuneUser: Equatable {
    let id: String
    let email: String
}

struct SavedSession: Decodable, Identifiable {
    let id: String
    let startedAt: String
    let endedAt: String
    let graphImages: [String: String]
    let stressPoints: [StressPoint]
    let avgStress: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case graphImages = "graph_images"
        case stressPoints = "stress_points"
        case avgStress = "avg_stress"
    }

    var startDate: Date {
        ISO8601DateFormatter().date(from: startedAt) ?? .distantPast
    }
}

@MainActor
final class SupabaseService: ObservableObject {
    @Published var user: AdaptuneUser?
    @Published var sessions: [SavedSession] = []
    @Published var restored = false
    @Published var busy = false
    @Published var message: String?
    @Published var showLiveSession = false

    private let projectURL: String
    private let anonKey: String
    private var accessToken: String?
    private var refreshToken: String?

    var configured: Bool { !projectURL.isEmpty && !anonKey.isEmpty }

    init() {
        projectURL = (Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        anonKey = (Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        accessToken = UserDefaults.standard.string(forKey: "supabase_access_token")
        refreshToken = UserDefaults.standard.string(forKey: "supabase_refresh_token")
    }

    func restore() async {
        guard configured else { restored = true; return }
        if accessToken != nil {
            do { try await loadCurrentUser() }
            catch {
                do { try await refreshSession(); try await loadCurrentUser() }
                catch { clearSession() }
            }
        }
        restored = true
    }

    func signIn(email: String, password: String) async {
        await authenticate(path: "/auth/v1/token?grant_type=password", email: email,
                           password: password, isSignup: false)
    }

    func signUp(email: String, password: String) async {
        await authenticate(path: "/auth/v1/signup", email: email, password: password, isSignup: true)
    }

    private func authenticate(path: String, email: String, password: String, isSignup: Bool) async {
        guard configured else { message = "Add SupabaseURL and SupabaseAnonKey to Info.plist first."; return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let data = try await request(path: path, method: "POST", body: ["email": email, "password": password], authenticated: false)
            let json = try jsonObject(data)
            if json["access_token"] is String {
                try acceptAuth(json)
                try await upsertUser()
                try await loadSessions()
            } else if isSignup {
                message = "Check your email to confirm your account, then log in."
            } else {
                throw ServiceError.message("Supabase did not return a session.")
            }
        } catch { message = error.localizedDescription }
    }

    func signOut() async {
        if accessToken != nil { _ = try? await request(path: "/auth/v1/logout", method: "POST", authenticated: true) }
        clearSession()
    }

    func startLiveSession(hub: SignalHub) {
        hub.endSession()
        showLiveSession = true
    }

    func finishAndSave(hub: SignalHub) async throws {
        guard let user else { throw ServiceError.message("Log in before saving a session.") }
        let sessionID = UUID().uuidString.lowercased()
        let startedAt = hub.sessionStartedAt
        let endedAt = Date()
        let points = hub.stressHistory
        let values = points.map(\.y)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        var graphPaths: [String: String] = [:]
        let graphData: [String: Data?] = [
            "bpm": SessionGraphRenderer.png(title: "BPM", values: hub.bpmHistory, color: UIColor(Theme.cBPM)),
            "hrv_diff": SessionGraphRenderer.png(title: "HRV differential", values: hub.hrvHistory, color: UIColor(Theme.cHRV)),
            "right_brain": nil, "left_brain": nil, "right_ear": nil, "left_ear": nil,
        ]
        for (channel, possibleData) in graphData {
            guard let data = possibleData else { continue }
            let path = "\(user.id)/\(sessionID)/\(channel).png"
            try await uploadGraph(data, path: path)
            graphPaths[channel] = path
        }
        let payload: [String: Any] = [
            "id": sessionID,
            "user_id": user.id,
            "started_at": Self.iso.string(from: startedAt),
            "ended_at": Self.iso.string(from: endedAt),
            "graph_images": graphPaths,
            "stress_points": points.map { ["x": $0.x, "y": $0.y] },
            "avg_stress": average.map { $0 as Any } ?? NSNull(),
        ]
        _ = try await request(path: "/rest/v1/sessions", method: "POST", body: payload,
                              authenticated: true, extraHeaders: ["Prefer": "return=minimal"])
        hub.endSession()
        showLiveSession = false
        try await loadSessions()
    }

    func loadSessions() async throws {
        guard user != nil else { sessions = []; return }
        let path = "/rest/v1/sessions?select=id,started_at,ended_at,graph_images,stress_points,avg_stress&order=started_at.desc"
        let data = try await request(path: path, authenticated: true)
        sessions = try JSONDecoder().decode([SavedSession].self, from: data)
    }

    func graphImage(path: String) async throws -> UIImage {
        let data = try await request(path: "/storage/v1/object/authenticated/session-graphs/\(path)", authenticated: true)
        guard let image = UIImage(data: data) else { throw ServiceError.message("The saved graph image is invalid.") }
        return image
    }

    private func uploadGraph(_ data: Data, path: String) async throws {
        _ = try await request(path: "/storage/v1/object/session-graphs/\(path)", method: "POST",
                              data: data, authenticated: true,
                              extraHeaders: ["Content-Type": "image/png", "x-upsert": "true"])
    }

    private func loadCurrentUser() async throws {
        let data = try await request(path: "/auth/v1/user", authenticated: true)
        let json = try jsonObject(data)
        guard let id = json["id"] as? String else { throw ServiceError.message("Saved login expired.") }
        user = AdaptuneUser(id: id, email: json["email"] as? String ?? "")
        try await upsertUser()
        try await loadSessions()
    }

    private func refreshSession() async throws {
        guard let refreshToken else { throw ServiceError.message("No refresh token.") }
        let data = try await request(path: "/auth/v1/token?grant_type=refresh_token", method: "POST",
                                     body: ["refresh_token": refreshToken], authenticated: false)
        try acceptAuth(try jsonObject(data))
    }

    private func acceptAuth(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let authUser = json["user"] as? [String: Any],
              let id = authUser["id"] as? String else { throw ServiceError.message("Invalid Supabase login response.") }
        accessToken = access; refreshToken = refresh
        user = AdaptuneUser(id: id, email: authUser["email"] as? String ?? "")
        UserDefaults.standard.set(access, forKey: "supabase_access_token")
        UserDefaults.standard.set(refresh, forKey: "supabase_refresh_token")
    }

    private func upsertUser() async throws {
        guard let user else { return }
        _ = try await request(path: "/rest/v1/users?on_conflict=id", method: "POST",
                              body: ["id": user.id, "email": user.email], authenticated: true,
                              extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"])
    }

    private func clearSession() {
        accessToken = nil; refreshToken = nil; user = nil; sessions = []; showLiveSession = false
        UserDefaults.standard.removeObject(forKey: "supabase_access_token")
        UserDefaults.standard.removeObject(forKey: "supabase_refresh_token")
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil,
                         data: Data? = nil, authenticated: Bool,
                         extraHeaders: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: projectURL + path) else { throw ServiceError.message("Invalid Supabase URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authenticated ? (accessToken ?? "") : anonKey)", forHTTPHeaderField: "Authorization")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let data { request.httpBody = data }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let json = (try? jsonObject(responseData)) ?? [:]
            let detail = json["msg"] as? String ?? json["message"] as? String ?? json["error_description"] as? String ?? "Supabase request failed."
            throw ServiceError.message(detail)
        }
        return responseData
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.message("Unexpected Supabase response.")
        }
        return object
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum ServiceError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

private enum SessionGraphRenderer {
    static func png(title: String, values: [Double], color: UIColor) -> Data? {
        guard values.count > 1 else { return nil }
        let size = CGSize(width: 900, height: 360)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            UIColor(red: 0.051, green: 0.075, blue: 0.106, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let plot = CGRect(x: 40, y: 65, width: 820, height: 250)
            UIColor(red: 0.11, green: 0.15, blue: 0.20, alpha: 1).setStroke()
            for index in 1...3 {
                let y = plot.minY + plot.height * CGFloat(index) / 4
                context.cgContext.move(to: CGPoint(x: plot.minX, y: y))
                context.cgContext.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            context.cgContext.strokePath()
            (title as NSString).draw(at: CGPoint(x: 40, y: 20), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor(red: 0.39, green: 0.47, blue: 0.55, alpha: 1),
            ])
            var low = values.min()!, high = values.max()!
            if high - low < 0.0001 { low -= 1; high += 1 }
            let range = high - low
            let path = UIBezierPath()
            for (index, value) in values.enumerated() {
                let x = plot.minX + plot.width * CGFloat(index) / CGFloat(max(1, values.count - 1))
                let y = plot.maxY - plot.height * CGFloat((value - low) / range)
                index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            color.setStroke(); path.lineWidth = 4; path.lineJoinStyle = .round; path.stroke()
        }
    }
}
