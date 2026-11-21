import AppKit
import SwiftUI

/// Ties it together: what's playing → find (or load saved) lyrics → show them.
@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case idle               // nothing playing
        case searching
        case found
        case notFound           // nothing online; user can paste
    }

    let nowPlaying = NowPlayingMonitor()
    let library = LyricsLibrary()
    let settings = AppSettings()
    let listener = Listener()

    @Published private(set) var song: SavedSong?
    @Published private(set) var status: Status = .idle

    private var searchTask: Task<Void, Never>?
    private var lastKey: String?

    /// Whether the floating lyrics island is showing. The app opens with the dashboard instead.
    @Published var islandShown = false
    /// Message after trying to play a saved song in its app (shown as a toast).
    @Published var playMessage: String?
    /// A song whose app isn't known yet; the dashboard asks which app to open it in.
    @Published var choosingApp: SavedSong?
    /// Moves the island back to bottom-center (set up by the app delegate).
    var resetIsland: () -> Void = {}

    /// Short message about the last 汽水音乐 link import, shown on the Now Playing page.
    @Published var qishuiMessage: String?
    @Published private(set) var qishuiBusy = false
    private var pasteboardCount = NSPasteboard.general.changeCount
    private var pasteboardTimer: Timer?

    /// Listening test: where in the song it started, and the result once stopped.
    @Published private(set) var listenStart: Double?
    @Published private(set) var listenReport: ListenScore.Report?

    init() {
        nowPlaying.start()
        // Songs saved before the app was recorded: 汽水音乐 lyrics mean it came from 汽水音乐.
        for var s in library.songs where s.app == nil && s.source == "汽水音乐" {
            s.app = "com.soda.music"
            library.save(s)
        }
        // A 汽水音乐 share link copied while a song has no lyrics gets imported automatically.
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPasteboard() }
        }
        Task { @MainActor in
            for await art in nowPlaying.$artwork.values {
                if let art, let id = self.song?.id { self.library.saveArtwork(art, for: id) }
            }
        }
        // React to song changes.
        Task { @MainActor in
            for await track in nowPlaying.$track.values {
                self.trackChanged(track)
            }
        }
    }

    /// Playback time for the lyrics, including the song's own offset.
    func position(at date: Date) -> Double {
        nowPlaying.position(at: date) + (song?.offset ?? 0) + settings.leadTime
    }

    private func trackChanged(_ track: Track?) {
        guard let track else {
            lastKey = nil
            status = .idle
            return
        }
        guard track.key != lastKey else { return }
        lastKey = track.key
        searchTask?.cancel()
        if ProcessInfo.processInfo.environment["YY_FORCE_NOTFOUND"] != nil {   // developer check for the empty state
            song = nil
            status = .notFound
            return
        }

        if let (found, fuzzy) = library.song(matching: track) {
            var saved = found
            if fuzzy {
                // Remember this app's name for the song so next time it's an exact match.
                saved.aliases = (saved.aliases ?? []) + [track.key]
            }
            saved = played(saved, on: track)
            library.save(saved)
            song = saved
            status = .found
            keepArtwork()
            return
        }
        song = nil
        status = .searching
        searchTask = Task { [weak self] in
            let found = await LyricsService.find(for: track)
            guard let self, !Task.isCancelled, self.lastKey == track.key else { return }
            if let found {
                let s = self.played(found, on: track)
                self.library.save(s)
                self.song = s
                self.status = .found
                self.keepArtwork()
            } else {
                self.status = .notFound
            }
        }
    }

    func retrySearch() {
        lastKey = nil
        if let t = nowPlaying.track {
            if let s = library.song(forKey: t.key) { library.delete(s) }
            trackChanged(t)
        }
    }

    /// Save lyrics the user pasted in (LRC with times, or plain text).
    func savePasted(_ text: String, title: String, artist: String) {
        let (lines, timing) = LyricsParser.pasted(text)
        guard !lines.isEmpty else { return }
        let key = SongKey.make(title: title, artist: artist)
        let s = SavedSong(id: key, title: TitleCleaner.title(title), artist: TitleCleaner.artist(artist),
                          duration: nowPlaying.track?.duration, source: "Pasted", timing: timing, lines: lines)
        library.save(s)
        if nowPlaying.track?.key == key {
            song = s
            status = .found
        }
    }

    /// Notes which app the song played in, a link back to it, and the play count.
    private func played(_ s: SavedSong, on track: Track) -> SavedSong {
        var s = s
        if s.app != track.bundleID { s.playLink = nil }
        s.app = track.bundleID
        s.playCount = (s.playCount ?? 0) + 1
        s.lastPlayed = Date()
        if s.playLink == nil, let link = Player.currentLink(for: track) { s.playLink = link }
        return s
    }

    /// Opens a saved song in the app it came from, behind the dashboard.
    func play(_ s: SavedSong) {
        guard let app = s.app else { choosingApp = s; return }
        Task {
            switch await Player.play(s) {
            case .playing: toast("Opening in \(Track.name(forBundle: app))…")
            case .openedApp(let name):
                toast("\(name) opened behind this window. It can't be told which song to play, so \"\(s.title)\" is copied: press ⌘V in its search.")
            case .unavailable:
                toast("Couldn't open \(s.title).")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Remembers which app a song belongs to, then plays it there.
    func play(_ s: SavedSong, in app: String) {
        var s = s
        if s.app != app { s.playLink = nil }
        s.app = app
        update(s)
        play(s)
    }

    /// Short confirmation shown in the middle of the dashboard for 3 seconds.
    struct Notice: Equatable { var id = UUID(); var title: String; var detail: String? }
    @Published var notice: Notice?
    private var noticeTask: Task<Void, Never>?

    func notify(_ title: String, detail: String? = nil) {
        noticeTask?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) { notice = Notice(title: title, detail: detail) }
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.35)) { notice = nil }
        }
    }

    private var toastTask: Task<Void, Never>?
    func toast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { playMessage = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { playMessage = nil }
        }
    }

    /// Plays from a lyric line's time (undoing the song's timing shift and the lead time).
    func seek(toLyricTime t: Double) {
        nowPlaying.seek(to: t - (song?.offset ?? 0) - settings.leadTime - 0.2)
    }

    private func keepArtwork() {
        if let art = nowPlaying.artwork, let id = song?.id { library.saveArtwork(art, for: id) }
    }

    // MARK: 汽水音乐 share links

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteboardCount else { return }
        pasteboardCount = pb.changeCount
        // Accepted when the song has no lyrics, or when it's playing in 汽水音乐 and its lyrics
        // came from somewhere else (汽水音乐's own are exact for its remixes, with word timing).
        let wanted = status == .notFound
            || (nowPlaying.track?.bundleID == "com.soda.music" && song?.source != "汽水音乐")
        guard wanted, !qishuiBusy, let text = pb.string(forType: .string),
              Qishui.looksLikeLink(text) else { return }
        Task { await importQishui(text) }
    }

    /// Gets lyrics from a 汽水音乐 share link and attaches them to the song that's playing
    /// (when it's the same song), so they load automatically from now on.
    func importQishui(_ link: String) async {
        qishuiBusy = true
        defer { qishuiBusy = false }
        qishuiMessage = "Getting lyrics from 汽水音乐…"
        guard let result = try? await Qishui.fetch(link: link) else {
            qishuiMessage = "That link didn't have lyrics. Make sure it's a song's share link from 汽水音乐."
            return
        }
        var s = result.song
        if let track = nowPlaying.track, isSameSong(result, track) {
            let ownKey = s.id
            s.id = track.key
            s.aliases = ownKey == track.key ? nil : [ownKey]
            if track.duration > 0 { s.duration = track.duration }
            if let old = library.song(forKey: track.key) { library.delete(old) }
            library.save(s)
            song = s
            lastKey = track.key
            status = .found
            keepArtwork()
            qishuiMessage = "Saved \(s.title) from 汽水音乐 (\(timingLabel(s.timing)))."
        } else {
            library.save(s)
            qishuiMessage = "Saved \(s.title) by \(s.artist). It isn't the song playing now, so it'll show up when that song plays."
        }
    }

    private func isSameSong(_ r: Qishui.Result, _ t: Track) -> Bool {
        if r.duration > 0, t.duration > 0 { return abs(r.duration - t.duration) < 3 }
        let titles = Set(TitleCleaner.searchVariants(t.title).map { $0.lowercased() })
        return titles.contains(r.title.lowercased())
    }

    // MARK: Listening (speech recognition)

    /// Starts listening to the app that's playing. With lyrics already saved, it's an accuracy test.
    func startListening() {
        guard let track = nowPlaying.track else { return }
        listenReport = nil
        listenStart = nowPlaying.position()
        let hints = song?.lines.map(\.text) ?? []
        Task {
            await listener.start(bundleID: track.bundleID, hints: hints) { [weak self] in
                self?.nowPlaying.position() ?? 0
            }
        }
    }

    /// Stops listening. A song with lyrics gets a score; a song without gets the heard lyrics saved.
    func stopListening() {
        listener.stop()
        defer { listenStart = nil }
        guard let from = listenStart, let track = nowPlaying.track else { return }
        let to = nowPlaying.position()
        if let s = song, s.timing != .none || !s.lines.isEmpty, s.source != "Heard" {
            listenReport = ListenScore.compare(heard: listener.heard, with: s, from: from, to: to)
            return
        }
        let lines = listener.lines()
        guard !lines.isEmpty else { return }
        var s = song?.source == "Heard" ? song! : SavedSong(
            id: track.key, title: TitleCleaner.title(track.title), artist: TitleCleaner.artist(track.artist),
            duration: track.duration, source: "Heard", timing: .word, lines: [])
        // Keep lines from earlier listens that don't overlap this one.
        s.lines = (s.lines.filter { $0.start < from - 0.5 || $0.start > to } + lines).sorted { $0.start < $1.start }
        library.save(s)
        song = s
        status = .found
        keepArtwork()
    }

    func update(_ s: SavedSong) {
        library.save(s)
        if song?.id == s.id { song = s }
    }

    func delete(_ s: SavedSong) {
        library.delete(s)
        if song?.id == s.id {
            song = nil
            lastKey = nil
            status = .notFound
        }
    }
}
