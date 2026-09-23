import Foundation

/// Conservative local matching: remasters may match, but live/remix/cover versions
/// must be explicitly requested. No Spotify metadata is sent to an AI service.
enum SpotifyTrackMatcher {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func titleKey(_ title: String) -> String {
        var text = title.replacingOccurrences(of: #"[\[(][^\])]*remaster[^\])]*[\])]"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s*-\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return normalized(text)
    }
    static func artistKey(_ artist: String) -> String {
        normalized(artist.replacingOccurrences(of: #"\s+(?:feat\.?|ft\.?)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }
    static func matches(artist: String, title: String, actualTitle: String, actualArtists: [String]) -> Bool {
        let wanted = artistKey(artist)
        return !wanted.isEmpty && !titleKey(title).isEmpty &&
            titleKey(title) == titleKey(actualTitle) && actualArtists.map(artistKey).contains(wanted)
    }
}
