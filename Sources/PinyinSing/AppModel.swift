import AppKit
import CoreImage
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
    let wordSync = WordSync()
    private var syncTimer: Timer?
    private var lastPos: Double = 0
    private var lastTick = Date()

    @Published private(set) var song: SavedSong?
    @Published private(set) var status: Status = .idle

    private var searchTask: Task<Void, Never>?
    private var lastKey: String?

    /// Whether the floating lyrics island is showing. The app opens with the dashboard instead.
    @Published var islandShown = false
    /// The platform the current song is playing on (YouTube and Spotify can both be Chrome).
    @Published private(set) var platform: String?
    private var platformLink: String?

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
        wordSync.onSynced = { [weak self] synced, count in
            guard let self else { return }
            // Keep any edits made while it was aligning (pinyin fixes, likes), add the word times.
            var s = self.library.song(forKey: synced.id) ?? synced
            for (i, line) in synced.lines.enumerated() where i < s.lines.count && line.words != nil && s.lines[i].words == nil {
                s.lines[i].words = line.words
                s.lines[i].start = line.start
            }
            self.update(s)
            self.notify("Words synced", detail: "\(count) lines of \(s.title) now follow the singing")
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncTick() }
        }
        // Songs saved before platforms: turn the stored app into a platform, start the list of
        // platforms, and move the single link into the per-platform links.
        for var s in library.songs {
            var changed = false
            if s.app == nil, s.source == "汽水音乐" { s.app = "qishui"; changed = true }
            if let a = s.app, a.contains(".") { s.app = Platform.migrate(a); changed = true }
            if s.apps == nil, let a = s.app { s.apps = [a]; changed = true }
            if let link = s.playLink, let a = s.app {
                s.links = (s.links ?? [:]).merging([a: link]) { old, _ in old }
                s.playLink = nil
                changed = true
            }
            if changed { library.save(s) }
        }
        // A 汽水音乐 share link copied while a song has no lyrics gets imported automatically.
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPasteboard() }
        }
        Task { @MainActor in
            for await art in nowPlaying.$artwork.values {
                if let art, let id = self.song?.id { self.library.saveArtwork(art, for: id) }
                // The Album theme takes its color from the art.
                withAnimation(.easeInOut(duration: 0.8)) { self.settings.artColor = art.flatMap(averageColor) }
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

    /// Records line-timed songs so Sync words can time each character. A pause or jump ends
    /// the current recording (it gets synced) and a new one starts when playback continues.
    private func syncTick() {
        let now = Date()
        let pos = nowPlaying.position(at: now)
        defer { lastPos = pos; lastTick = now }
        let lyricPos = pos + (song?.offset ?? 0)
        if let id = wordSync.recordingSongID {
            let expected = lastPos + now.timeIntervalSince(lastTick)
            let lastLyric = lastPos + (song?.offset ?? 0)
            if id != song?.id || !nowPlaying.isPlaying || abs(pos - expected) > 1.5 {
                wordSync.stopRecording(at: lastLyric, keep: true)
            } else {
                return
            }
        }
        guard settings.syncWords, nowPlaying.isPlaying, let s = song, status == .found,
              let track = nowPlaying.track, WordSync.needsSync(s), listener.state != .listening else { return }
        wordSync.startRecording(s, bundleID: track.bundleID, at: lyricPos)
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
        let (p, link) = Player.identify(track)
        platform = p
        platformLink = link
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

    /// Notes the platform it played on (added to its list, so a song played on 汽水音乐 and on
    /// Spotify shows up under both), a link back to it, and the play count.
    private func played(_ s: SavedSong, on track: Track) -> SavedSong {
        var s = s
        let p = platform ?? Platform.from(bundle: track.bundleID)
        guard p != "browser" else {   // unknown site: count the play, don't file it anywhere
            s.playCount = (s.playCount ?? 0) + 1
            s.lastPlayed = Date()
            return s
        }
        s.app = p
        if !(s.apps ?? []).contains(p) { s.apps = (s.apps ?? []) + [p] }
        if let link = platformLink { s.links = (s.links ?? [:]).merging([p: link]) { _, new in new } }
        s.playCount = (s.playCount ?? 0) + 1
        s.lastPlayed = Date()
        return s
    }

    /// Opens a saved song in the app it came from, behind the dashboard.
    func play(_ s: SavedSong) {
        guard s.app != nil else { choosingApp = s; return }
        Task {
            switch await Player.play(s) {
            case .playing(let name): toast("Opening in \(name)…")
            case .openedApp(let name):
                toast("\(name) opened behind this window. It can't be told which song to play, so \"\(s.title)\" is copied: press ⌘V in its search.")
            case .unavailable:
                toast("Couldn't open \(s.title).")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Plays a song on a chosen platform and remembers it there.
    func play(_ s: SavedSong, in platform: String) {
        var s = s
        s.app = platform
        if !(s.apps ?? []).contains(platform) { s.apps = (s.apps ?? []) + [platform] }
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

/// Average color of an image (Core Image's area average), for the Album theme.
func averageColor(_ image: NSImage) -> Color? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let ci = CIImage(cgImage: cg)
    guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
          let out = f.outputImage else { return nil }
    var px = [UInt8](repeating: 0, count: 4)
    CIContext(options: [.workingColorSpace: NSNull()])
        .render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
    return Color(.sRGB, red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
}
