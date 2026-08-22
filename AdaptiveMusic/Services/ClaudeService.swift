import Foundation

/// Claude is the music brain: given the user's vibe / artist / song and their current
/// stress level, it names real songs (resolved to playable tracks via Spotify Search).
/// The user's own Anthropic API key is entered in the Personalize card.
final class ClaudeService: ObservableObject {

    @Published var keySet: Bool = UserDefaults.standard.string(forKey: "anthropic_key")?.isEmpty == false

    static let model = "claude-sonnet-5"

    var apiKey: String? {
        get { UserDefaults.standard.string(forKey: "anthropic_key") }
        set {
            UserDefaults.standard.set(newValue, forKey: "anthropic_key")
            keySet = (newValue?.isEmpty == false)
        }
    }

    private static let system =
        "You are the music supervisor of a real-time stress-management app. The app measures the " +
        "listener's stress from their heart rate and HRV and plays music to regulate it. You choose " +
        "real, existing songs that are available on Spotify. Always answer with ONLY the JSON that " +
        "was requested — no prose, no code fences."

    private static let goals: [StressLabel: String] = [
        .calm: "keep the listener settled and relaxed",
        .mild: "gently steady the listener and ease tension",
        .stressed: "actively calm the listener down and reduce acute stress",
    ]

    struct Suggestion { let artist: String; let title: String }

    enum ClaudeError: Error { case noKey, badResponse }

    private func complete(_ prompt: String, maxTokens: Int = 700,
                          system: String = ClaudeService.system) async throws -> String {
        guard let key = apiKey, !key.isEmpty else { throw ClaudeError.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ClaudeService.model, "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = j["content"] as? [[String: Any]] else { throw ClaudeError.badResponse }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                      .joined()
    }

    func analyzeSession(points: [StressPoint], average: Double?) async throws -> String {
        let compact = points.prefix(3600).map { ["seconds": round($0.x * 10) / 10,
                                                "stress": round($0.y * 10) / 10] }
        let data = try JSONSerialization.data(withJSONObject: compact)
        let pointJSON = String(data: data, encoding: .utf8) ?? "[]"
        let prompt = "Analyze this Adaptune session. Average stress score: " +
            String(format: "%.1f", average ?? 0) + "/100. Time-series points: \(pointJSON). " +
            "Identify the overall pattern, notable rises or recoveries, and one practical suggestion. " +
            "Answer only JSON: {\"analysis\": \"...\"}"
        let wellnessSystem = "You interpret wellness stress-session charts. Be concise and supportive. " +
            "Do not diagnose medical conditions. Return only the requested JSON."
        let reply = try await complete(prompt, maxTokens: 500, system: wellnessSystem)
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let analysis = object["analysis"] as? String, !analysis.isEmpty else {
            throw ClaudeError.badResponse
        }
        return analysis
    }

    private func parseJSONArray(_ text: String) -> [[String: Any]] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
        }
        guard let i = t.firstIndex(of: "["), let j = t.lastIndex(of: "]") , i < j else { return [] }
        let body = String(t[i...j])
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [[String: Any]] ?? []
    }

    /// Candidate songs for a personalization mode.
    func pickSongs(mode: PersonalizeMode, value: String, label: StressLabel,
                   count: Int = 6, exclude: [String]) async throws -> [Suggestion] {
        let goal = ClaudeService.goals[label] ?? ClaudeService.goals[.mild]!
        var ask: String
        switch mode {
        case .vibe:
            ask = "The listener described their vibe as: \"\(value)\".\n" +
                  "Their current stress level is \(label.rawValue); the therapeutic goal is to \(goal).\n" +
                  "Output \(count) real songs on Spotify matching that vibe AND the goal."
        case .artist:
            ask = "The listener's favorite artist is: \"\(value)\".\n" +
                  "Their current stress level is \(label.rawValue); the therapeutic goal is to \(goal).\n" +
                  "Output \(count) real songs BY \"\(value)\" ONLY that best serve the goal."
        case .song:
            ask = "The listener's favorite song is: \"\(value)\".\n" +
                  "Their current stress level is \(label.rawValue); the therapeutic goal is to \(goal).\n" +
                  "Identify that song's primary artist, then output \(count) real songs by that same " +
                  "artist (the favorite song itself may be included once) that fit the goal."
        case .playlist:
            ask = ""                                        // playlist mode never asks Claude
        }
        if !exclude.isEmpty {
            ask += "\nDo NOT suggest any of these (already played): " +
                   exclude.suffix(30).joined(separator: "; ")
        }
        ask += "\nAnswer with ONLY a JSON array: [{\"artist\": \"...\", \"title\": \"...\"}]"
        let reply = try await complete(ask)
        return parseJSONArray(reply).compactMap { d in
            guard let a = d["artist"] as? String, let t = d["title"] as? String,
                  !a.isEmpty, !t.isEmpty else { return nil }
            return Suggestion(artist: a, title: t)
        }
    }

    /// Choose only from real Spotify playlist entries supplied by the app. The
    /// position is the actual playlist offset, never an invented song or index.
    func pickPlaylistPosition(candidates: [PlaylistTrackCandidate],
                              label: StressLabel) async -> Int? {
        guard keySet, !candidates.isEmpty else { return nil }
        let goal = ClaudeService.goals[label] ?? ClaudeService.goals[.mild]!
        let listing = candidates.map {
            "\($0.position): \($0.track.artist) — \($0.track.name)"
        }.joined(separator: "\n")
        let ask = "The listener's stress level is \(label.rawValue). The therapeutic goal is to \(goal).\n" +
                  "Choose the one most suitable song from this exact Spotify playlist. " +
                  "You may choose ONLY one listed playlist position.\n\(listing)\n" +
                  "Answer ONLY JSON: {\"index\": <listed playlist position>}"
        guard let reply = try? await complete(ask, maxTokens: 60),
              let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = (try? JSONSerialization.jsonObject(
                  with: Data(String(reply[start...end]).utf8))) as? [String: Any],
              let index = data["index"] as? Int,
              candidates.contains(where: { $0.position == index }) else { return nil }
        return index
    }

    /// Which of these candidate tracks is the best instrumental version? (index, or -1)
    func pickInstrumental(of track: String, by artist: String,
                          candidates: [SpotifyTrack]) async -> Int {
        guard keySet, candidates.count > 1 else { return candidates.isEmpty ? -1 : 0 }
        let listing = candidates.prefix(8).enumerated()
            .map { "\($0.offset): \($0.element.artist) — \($0.element.name)" }
            .joined(separator: "\n")
        let ask = "Which of these Spotify tracks is the best INSTRUMENTAL version of " +
                  "\"\(track)\" by \(artist) (same melody, no vocals)?\n\(listing)\n" +
                  "Answer ONLY JSON: {\"index\": <number>} — use {\"index\": -1} if none match."
        guard let reply = try? await complete(ask, maxTokens: 60),
              let i = reply.firstIndex(of: "{"), let j = reply.lastIndex(of: "}"), i < j,
              let d = (try? JSONSerialization.jsonObject(with: Data(String(reply[i...j]).utf8))) as? [String: Any],
              let idx = d["index"] as? Int else { return 0 }
        if idx == -1 { return -1 }
        return (0..<candidates.count).contains(idx) ? idx : 0
    }
}
