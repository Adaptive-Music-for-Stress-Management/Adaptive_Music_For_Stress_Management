import Foundation

@main struct MatcherChecks {
    static func main() {
        let matches = SpotifyTrackMatcher.matches
        precondition(matches("coldplay", "Yellow", "YELLOW (2011 Remastered)", ["Coldplay"]))
        precondition(!matches("Coldplay", "Yellow", "Yellow - Live", ["Coldplay"]))
        precondition(!matches("Queen", "Song", "Song", ["Queen Tribute"]))
        precondition(matches("Beyoncé", "Song", "Song", ["Beyonce"]))
        precondition(matches("Earth, Wind & Fire", "September", "September", ["Earth, Wind & Fire"]))
        precondition(matches("Artist feat. Guest", "Song (Live)", "Song - Live", ["Artist", "Guest"]))
        precondition(!matches("Artist", "Song", "Song - Remix", ["Artist"]))
        precondition(!matches("", "", "", [""]))
        print("8 Spotify matcher checks passed")
    }
}
