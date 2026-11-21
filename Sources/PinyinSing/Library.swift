import AppKit
import CryptoKit

/// Every song's lyrics are saved as one JSON file in
/// ~/Library/Application Support/Yues Yinyue/Songs, so they never need to be found twice.
@MainActor
final class LyricsLibrary: ObservableObject {
    @Published private(set) var songs: [SavedSong] = []
    @Published private(set) var albums: [Album] = []

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The folder keeps the app's earlier name ("Yues Yinyue") so saved songs carry over.
        let dir = base.appendingPathComponent("Yues Yinyue/Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init() {
        reload()
        loadAlbums()
    }

    // MARK: Albums (saved as albums.json next to the Songs folder)

    private var albumsFile: URL { folder.deletingLastPathComponent().appendingPathComponent("albums.json") }

    /// "Liked Songs" is a built-in album: always first, can't be renamed or deleted.
    static let likedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func loadAlbums() {
        albums = (try? Data(contentsOf: albumsFile)).flatMap { try? decoder.decode([Album].self, from: $0) } ?? []
        if let i = albums.firstIndex(where: { $0.id == Self.likedID }) {
            let liked = albums.remove(at: i)
            albums.insert(liked, at: 0)
        } else {
            albums.insert(Album(id: Self.likedID, name: "Liked Songs"), at: 0)
            saveAlbums()
        }
    }

    func isLiked(_ songID: String) -> Bool {
        albums.first?.id == Self.likedID && albums[0].songIDs.contains(songID)
    }

    func toggleLike(_ songID: String) {
        if isLiked(songID) { remove(songID, from: Self.likedID) } else {
            // Newest likes first.
            guard let i = albums.firstIndex(where: { $0.id == Self.likedID }) else { return }
            albums[i].songIDs.insert(songID, at: 0)
            saveAlbums()
        }
    }

    private func saveAlbums() {
        if let d = try? encoder.encode(albums) { try? d.write(to: albumsFile, options: .atomic) }
    }

    @discardableResult
    func newAlbum(_ name: String, with songID: String? = nil) -> Album {
        var a = Album(name: name.isEmpty ? "New Album" : name)
        if let songID { a.songIDs = [songID] }
        albums.append(a)
        saveAlbums()
        return a
    }

    func renameAlbum(_ id: UUID, to name: String) {
        guard id != Self.likedID, let i = albums.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        albums[i].name = name
        saveAlbums()
    }

    func deleteAlbum(_ id: UUID) {
        guard id != Self.likedID else { return }
        albums.removeAll { $0.id == id }
        saveAlbums()
    }

    func add(_ songID: String, to album: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == album }), !albums[i].songIDs.contains(songID) else { return }
        albums[i].songIDs.append(songID)
        saveAlbums()
    }

    func remove(_ songID: String, from album: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == album }) else { return }
        albums[i].songIDs.removeAll { $0 == songID }
        saveAlbums()
    }

    func songs(in album: Album) -> [SavedSong] {
        album.songIDs.compactMap { id in songs.first { $0.id == id } }
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        songs = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SavedSong.self, from: Data(contentsOf: $0)) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func song(forKey key: String) -> SavedSong? {
        songs.first { $0.id == key || ($0.aliases ?? []).contains(key) }
    }

    /// Finds a saved song even when another app names it a bit differently:
    /// exact key / known alias first, then same cleaned title + same length (within 2 s).
    func song(matching track: Track) -> (song: SavedSong, fuzzy: Bool)? {
        if let s = song(forKey: track.key) { return (s, false) }
        guard track.duration > 0 else { return nil }
        let titles = Set(TitleCleaner.searchVariants(track.title).map { $0.lowercased() })
        let hit = songs.first { s in
            guard let d = s.duration, abs(d - track.duration) < 2 else { return false }
            return titles.contains(s.title.lowercased())
        }
        return hit.map { ($0, true) }
    }

    func save(_ song: SavedSong) {
        guard let data = try? encoder.encode(song) else { return }
        try? data.write(to: file(for: song.id), options: .atomic)
        if let i = songs.firstIndex(where: { $0.id == song.id }) {
            songs[i] = song
        } else {
            songs.insert(song, at: 0)
        }
    }

    private var artCache: [String: NSImage] = [:]

    /// Small cover image saved next to the song's lyrics.
    func artwork(for id: String) -> NSImage? {
        if let a = artCache[id] { return a }
        let url = file(for: id).deletingPathExtension().appendingPathExtension("jpg")
        guard let img = NSImage(contentsOf: url) else { return nil }
        artCache[id] = img
        return img
    }

    func saveArtwork(_ image: NSImage, for id: String) {
        guard artwork(for: id) == nil else { return }
        let side: CGFloat = 400
        let small = NSImage(size: NSSize(width: side, height: side))
        small.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        try? jpg.write(to: file(for: id).deletingPathExtension().appendingPathExtension("jpg"), options: .atomic)
        artCache[id] = small
        objectWillChange.send()
    }

    func delete(_ song: SavedSong) {
        for a in albums where a.songIDs.contains(song.id) { remove(song.id, from: a.id) }
        try? FileManager.default.removeItem(at: file(for: song.id))
        try? FileManager.default.removeItem(at: file(for: song.id).deletingPathExtension().appendingPathExtension("jpg"))
        artCache[song.id] = nil
        songs.removeAll { $0.id == song.id }
    }

    func revealInFinder() {
        NSWorkspaceBridge.open(folder)
    }

    private func file(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(hash).json")
    }
}

import AppKit
enum NSWorkspaceBridge {
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
