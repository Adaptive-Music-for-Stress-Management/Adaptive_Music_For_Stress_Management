import Foundation

struct CatalogSong: Decodable, Identifiable {
    let id: String
    let title: String
    let author: String
    let lyrics: String
    let audio: String
    let countries: [String]
    let sources: [String]
    let basis: String
    var recordingURL: URL? {
        Bundle.main.url(forResource: (audio as NSString).deletingPathExtension,
                        withExtension: (audio as NSString).pathExtension, subdirectory: "Karaoke")
        ?? Bundle.main.url(forResource: (audio as NSString).deletingPathExtension, withExtension: (audio as NSString).pathExtension)
    }
}
enum KaraokeCatalog {
    static func load() -> [CatalogSong] {
        struct Catalog: Decodable { let songs: [CatalogSong] }
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Karaoke")
                ?? Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.songs.filter { $0.recordingURL != nil }
    }
}
