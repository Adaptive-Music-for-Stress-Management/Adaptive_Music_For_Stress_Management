import Foundation

struct LyricLine: Identifiable {
    let id = UUID()
    let ms: Int          // -1 for unsynced lines
    let text: String
}

/// Spotify-style lyrics from LRCLIB (https://lrclib.net) — free, keyless, time-synced
/// when available. Returns nil when the song has no usable lyrics (karaoke then fails
/// with the spec's apology message).
enum LyricsService {

    static func fetch(track: String, artist: String, durationMs: Int?) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: track),
                     URLQueryItem(name: "artist_name", value: artist)]
        if let durationMs { items.append(.init(name: "duration", value: String(durationMs / 1000))) }
        comps.queryItems = items
        var record = await getJSON(comps.url!)
        if record == nil {                                    // fuzzy fallback
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [.init(name: "track_name", value: track),
                                 .init(name: "artist_name", value: artist)]
            if let url = search.url,
               let list = await getJSONArray(url), let first = list.first {
                record = first
            }
        }
        guard let record, (record["instrumental"] as? Bool) != true else { return nil }
        if let synced = record["syncedLyrics"] as? String, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return lines }
        }
        if let plain = record["plainLyrics"] as? String, !plain.isEmpty {
            return plain.components(separatedBy: "\n").map { LyricLine(ms: -1, text: $0) }
        }
        return nil
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in lrc.components(separatedBy: "\n") {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let text = regex.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length),
                                                      withTemplate: "")
                            .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(LyricLine(ms: Int((Double(min) * 60 + sec) * 1000), text: text))
            }
        }
        return out.sorted { $0.ms < $1.ms }
    }

    private static func getJSON(_ url: URL) async -> [String: Any]? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func getJSONArray(_ url: URL) async -> [[String: Any]]? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}
