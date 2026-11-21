import SwiftUI

/// Navigation and pop-ups shared by every page of the dashboard.
@MainActor
final class LibraryUI: ObservableObject {
    enum Page: Hashable {
        case home, nowPlaying, songs(app: String?), album(UUID), customize, settings
    }
    struct AlbumRequest: Identifiable { let id = UUID(); var songID: String? }

    @Published var page: Page? = .home
    @Published var openSong: String?
    @Published var editing: SavedSong?
    @Published var deleting: SavedSong?
    @Published var namingAlbum: AlbumRequest?
    @Published var renamingAlbum: Album?
    /// Our own menu that's open right now (••• or + on a song, ••• on an album).
    @Published var popup: PopupState?

    func open(_ id: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { openSong = id }
    }
}

/// The dashboard: home, now playing, saved songs, albums, customization and settings.
struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @StateObject private var ui = LibraryUI()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, library: library, settings: settings, ui: ui)
            ZStack {
                if let id = ui.openSong, let s = library.songs.first(where: { $0.id == id }) {
                    SongDetail(model: model, library: library, settings: settings, ui: ui, song: s,
                               back: { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { ui.openSong = nil } })
                        .id(s.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    page.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(LivingBackdrop(image: model.nowPlaying.artwork, settings: settings))
        .environmentObject(settings)
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 620)
        .tint(settings.primary)
        .onChange(of: ui.page) { ui.openSong = nil }
        .onReceive(NotificationCenter.default.publisher(for: .init("debugPage"))) { n in
            switch n.object as? String {
            case "now": ui.page = .nowPlaying
            case "custom": ui.page = .customize
            case "settings": ui.page = .settings
            case "songs": ui.page = .songs(app: nil)
            default: break
            }
        }
        .onAppear {   // developer check: open a menu or dialog for --snapshot
            let env = ProcessInfo.processInfo.environment
            if let s = library.songs.first {
                if env["YY_DEBUG_POPUP"] == "album" { ui.popup = PopupState(kind: .addToAlbum(s), anchor: CGRect(x: 640, y: 240, width: 30, height: 30)) }
                if env["YY_DEBUG_POPUP"] == "song" { ui.popup = PopupState(kind: .songActions(s, inAlbum: nil), anchor: CGRect(x: 900, y: 240, width: 30, height: 30)) }
                if env["YY_DEBUG_POPUP"] == "new" { ui.namingAlbum = .init(songID: s.id) }
            }
        }
        // Notice in the middle: pops in, then floats up and fades away after 3 seconds.
        .overlay {
            if let n = model.notice {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(settings.primary)
                    Text(n.title).font(.system(size: 15, weight: .semibold))
                    if let d = n.detail {
                        Text(d).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 30).padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                .id(n.id)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: -24))))
                .allowsHitTesting(false)
            }
        }
        // Toast at the bottom for play results.
        .overlay(alignment: .bottom) {
            if let m = model.playMessage {
                Text(m).font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    .frame(maxWidth: 560)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .coordinateSpace(name: dashSpace)
        .overlay { PopupHost(model: model, library: library, settings: settings, ui: ui) }
    }

    @ViewBuilder
    private var page: some View {
        switch ui.page ?? .home {
        case .home:
            HomePage(model: model, library: library, settings: settings, nowPlaying: model.nowPlaying, ui: ui)
        case .nowPlaying:
            NowPlayingPage(model: model, settings: settings, nowPlaying: model.nowPlaying, listener: model.listener)
        case .songs(let app):
            SongsPage(model: model, library: library, settings: settings, ui: ui, app: app)
        case .album(let id):
            if let a = library.albums.first(where: { $0.id == id }) {
                AlbumPage(model: model, library: library, settings: settings, ui: ui, album: a)
            } else {
                Text("This album was deleted.").foregroundStyle(.secondary)
            }
        case .customize:
            CustomizationView(settings: settings)
        case .settings:
            SettingsView(model: model, settings: settings)
        }
    }

}

enum AppIcon {
    static func symbol(_ bundleID: String) -> String {
        switch bundleID {
        case "com.soda.music": return "bubbles.and.sparkles.fill"
        case "com.netease.163music": return "cloud.fill"
        case "com.spotify.client": return "dot.radiowaves.left.and.right"
        case "com.google.Chrome", "com.apple.Safari": return "play.rectangle.fill"
        default: return "app.fill"
        }
    }
}

/// On/off for the floating lyrics island, always at the bottom of the sidebar.
struct IslandSwitch: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "capsule.portrait.fill")
                .rotationEffect(.degrees(90))
                .foregroundStyle(model.islandShown ? settings.primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lyrics island").font(.system(size: 12, weight: .semibold))
                Text(model.islandShown ? "Showing" : "Hidden").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $model.islandShown).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

/// A small full-width button for the bottom of the sidebar. `on` fills its icon with the theme color.
struct SidebarButton: View {
    var symbol: String
    var title: String
    var on: Bool
    var tint: Color
    var action: () -> Void
    @Local private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? tint : .secondary)
                    .frame(width: 18)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(over ? 0.8 : 0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

// MARK: Cover art

/// The song's album art, or a soft color tile with its first character when there's none.
struct Cover: View {
    var image: NSImage?
    var title: String
    var tint: Color
    var corner: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Text(String(title.first ?? "♪"))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .minimumScaleFactor(0.2)
                            .padding(12)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

// MARK: Home

struct HomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var ui: LibraryUI
    @Local private var heroWidth: CGFloat = 900

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                        .font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(greeting).font(.system(size: 40, weight: .heavy, design: .rounded))
                }
                hero
                stats
                Shelf(title: "Jump back in", songs: recent, library: library, settings: settings, ui: ui, model: model,
                      empty: "Songs you play show up here.")
                Shelf(title: "Most played", songs: mostPlayed, library: library, settings: settings, ui: ui, model: model,
                      empty: nil)
                albumsShelf
                if !needsHelp.isEmpty {
                    Shelf(title: "Needs better lyrics", subtitle: "No timing yet, so they can't light up. Open one to fix it.",
                          songs: needsHelp, library: library, settings: settings, ui: ui, model: model, empty: nil)
                }
                Shelf(title: "Recently added", songs: Array(library.songs.prefix(12)), library: library, settings: settings,
                      ui: ui, model: model, empty: nil)
            }
            .padding(36)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Late night listening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    /// Art beside the info when there's room, above it when the window is narrow.
    private var hero: some View {
        Group {
            if heroWidth >= 700 {
                HStack(alignment: .center, spacing: 28) { heroArt; heroInfo.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                VStack(alignment: .leading, spacing: 20) { heroArt; heroInfo }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(26)
        .background(GeometryReader { g in
            Color.clear.onAppear { heroWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in heroWidth = w }
        })
        .glassCard(28)
    }

    private var heroArt: some View {
            Group {
                if settings.showDisc {
                    Turntable(nowPlaying: nowPlaying, settings: settings).frame(width: 170, height: 221)
                } else {
                    Cover(image: nowPlaying.artwork, title: nowPlaying.track?.title ?? "♪", tint: settings.primary, corner: 18)
                        .frame(width: 210, height: 210)
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
                }
            }
    }

    private var heroInfo: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    EqualizerBars(playing: nowPlaying.isPlaying, tint: settings.primary)
                    Text(nowPlaying.track.map { "NOW PLAYING · \($0.playerName)" } ?? "NOTHING PLAYING")
                        .font(.system(size: 11, weight: .bold)).tracking(1.2)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(settings.primary.opacity(0.18)))

                Text(nowPlaying.track.map { TitleCleaner.title($0.title) } ?? "Play a song in any music app")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if let t = nowPlaying.track {
                    Text(TitleCleaner.artist(t.artist)).font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                }

                // The line being sung, live, with its pinyin.
                if model.song != nil {
                    LyricsStage(model: model, settings: settings, nowPlaying: nowPlaying, fixedLines: 1)
                        .frame(height: settings.fontSize * (settings.showPinyin ? 2.05 : 1.35) + 22)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(settings.background.opacity(0.92)))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.vertical, 4)
                }

                if heroWidth >= 860 {
                    HStack(spacing: 12) { transport; heroButtons }
                } else {
                    VStack(alignment: .leading, spacing: 12) { transport; heroButtons }
                }
            }
    }

    @ViewBuilder private var transport: some View {
        if nowPlaying.track != nil {
            HStack(spacing: 12) {
                        CircleControl("backward.fill", size: 40, tint: settings.primary, filled: false) { nowPlaying.send(.previous) }
                        CircleControl(nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 52, tint: settings.primary, filled: true) {
                            nowPlaying.send(.togglePlayPause)
                        }
                        CircleControl("forward.fill", size: 40, tint: settings.primary, filled: false) { nowPlaying.send(.next) }
            }
        }
    }

    private var heroButtons: some View {
                HStack(spacing: 10) {
                    if nowPlaying.track != nil {
                        Button { ui.page = .nowPlaying } label: { Label("Full lyrics", systemImage: "quote.bubble.fill") }
                            .buttonStyle(GlassButton())
                    }
                    Button { model.islandShown.toggle() } label: {
                        Label(model.islandShown ? "Hide island" : "Show island", systemImage: "pip")
                            .fixedSize()
                    }
                    .buttonStyle(GlassButton())
                }
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
            StatTile(value: "\(library.songs.count)", label: "songs", symbol: "music.note")
            StatTile(value: "\(characters)", label: "characters", symbol: "character.textbox.zh")
            StatTile(value: "\(Set(library.songs.compactMap(\.app)).count)", label: "apps", symbol: "square.grid.2x2.fill")
            StatTile(value: "\(library.songs.reduce(0) { $0 + $1.lines.filter { $0.pinyinOverride != nil }.count })",
                     label: "pinyin fixes", symbol: "pencil")
        }
    }

    private var albumsShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your albums").font(.system(size: 20, weight: .bold, design: .rounded))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(library.albums) { a in
                        let songs = library.songs(in: a)
                        VStack(alignment: .leading, spacing: 8) {
                            AlbumArt(songs: songs, library: library, tint: settings.highlight, liked: a.id == LyricsLibrary.likedID)
                                .frame(width: 150, height: 150)
                            Text(a.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(songs.count) songs").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(width: 150)
                        .onTapGesture { ui.page = .album(a.id) }
                    }
                    Button { ui.namingAlbum = .init(songID: nil) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 30, weight: .medium))
                            Text("New album").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 150, height: 150)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recent: [SavedSong] {
        library.songs.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }.prefix(12).map { $0 }
    }
    private var mostPlayed: [SavedSong] {
        library.songs.filter { ($0.playCount ?? 0) > 1 }.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(12).map { $0 }
    }
    private var needsHelp: [SavedSong] { library.songs.filter { $0.timing == .none } }
    private var characters: Int {
        Set(library.songs.flatMap { $0.lines.flatMap { $0.text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) } } }).count
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(settings.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(settings.primary.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(18)
    }
}

/// Three little bars that bounce while music plays.
struct EqualizerBars: View {
    var playing: Bool
    var tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { i in
                    Capsule().fill(tint)
                        .frame(width: 3, height: playing ? 4 + 8 * abs(sin(t * (5 + Double(i) * 1.7) + Double(i))) : 4)
                }
            }
            .frame(height: 12, alignment: .bottom)
        }
    }
}

/// Round playback button; `filled` is the big main one.
struct CircleControl: View {
    let symbol: String
    let size: CGFloat
    let tint: Color
    let filled: Bool
    let action: () -> Void
    @Local private var over = false
    init(_ symbol: String, size: CGFloat, tint: Color, filled: Bool, action: @escaping () -> Void) {
        self.symbol = symbol; self.size = size; self.tint = tint; self.filled = filled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(filled ? Color.white : Color.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial)))
                .overlay(Circle().strokeBorder(.white.opacity(filled ? 0 : 0.12)))
                .shadow(color: .black.opacity(filled ? 0.25 : 0), radius: 8, y: 4)
                .scaleEffect(over ? 1.07 : 1)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { over = h } }
    }
}

/// A titled horizontal row of song covers.
struct Shelf: View {
    var title: String
    var subtitle: String? = nil
    var songs: [SavedSong]
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: LibraryUI
    @ObservedObject var model: AppModel
    var empty: String?

    var body: some View {
        if !songs.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }
                if songs.isEmpty, let empty {
                    Text(empty).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 20) {
                            ForEach(songs) { s in
                                SongCard(song: s, image: library.artwork(for: s.id), tint: settings.highlight,
                                         model: model, library: library, ui: ui)
                                    .frame(width: 150)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }
}

/// Up to four covers in a square, for an album.
struct AlbumArt: View {
    var songs: [SavedSong]
    @ObservedObject var library: LyricsLibrary
    var tint: Color
    var liked = false

    var body: some View {
        let covers = songs.prefix(4).map { ($0.title, library.artwork(for: $0.id)) }
        Group {
            if liked {
                // Liked Songs always has its own cover: a heart on a gradient.
                ZStack {
                    LinearGradient(colors: [Color(hex: "#FF5E8A"), Color(hex: "#8A5CFF")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "heart.fill").font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .minimumScaleFactor(0.3)
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if covers.count < 4 {
                Cover(image: covers.first?.1, title: covers.first?.0 ?? "♪", tint: tint)
            } else {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { Cover(image: covers[0].1, title: covers[0].0, tint: tint, corner: 0)
                              Cover(image: covers[1].1, title: covers[1].0, tint: tint, corner: 0) }
                    GridRow { Cover(image: covers[2].1, title: covers[2].0, tint: tint, corner: 0)
                              Cover(image: covers[3].1, title: covers[3].0, tint: tint, corner: 0) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }
}

// MARK: Songs & albums

struct SongsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: LibraryUI
    var app: String?
    @Local private var query = ""

    var body: some View {
        SongGrid(title: app.map { Track.name(forBundle: $0) } ?? "All Songs",
                 subtitle: app == nil ? nil : "Songs you last played in \(Track.name(forBundle: app!))",
                 songs: filtered, query: $query, model: model, library: library, settings: settings, ui: ui,
                 empty: library.songs.isEmpty ? "Songs show up here once their lyrics are found." : "No matches.")
    }

    private var filtered: [SavedSong] {
        var list = library.songs
        if let app { list = list.filter { $0.app == app } }
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }
}

struct AlbumPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: LibraryUI
    var album: Album
    @Local private var query = ""

    var body: some View {
        let songs = library.songs(in: album)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom, spacing: 22) {
                    AlbumArt(songs: songs, library: library, tint: settings.highlight, liked: album.id == LyricsLibrary.likedID)
                        .frame(width: 170, height: 170)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ALBUM").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Text(album.name).font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("\(songs.count) songs").foregroundStyle(.secondary)
                        HStack {
                            if let first = songs.first {
                                Button { model.play(first) } label: { Label("Play", systemImage: "play.fill") }
                                    .buttonStyle(GlassButton())
                            }
                            if album.id != LyricsLibrary.likedID {
                                MenuAnchorButton(ui: ui, kind: .albumActions(album)) {
                                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                                        .frame(width: 20, height: 16)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Capsule().fill(.ultraThinMaterial))
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                                        .contentShape(Capsule())
                                }
                            }
                        }
                    }
                }
                if songs.isEmpty {
                    Text(album.id == LyricsLibrary.likedID ? "Tap the heart on any song to add it here."
                                                           : "Add songs with the ••• button on any song → Add to Album.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22)], alignment: .leading, spacing: 26) {
                    ForEach(songs) { s in
                        SongCard(song: s, image: library.artwork(for: s.id), tint: settings.highlight,
                                 model: model, library: library, ui: ui, inAlbum: album)
                    }
                }
            }
            .padding(36)
        }
    }
}

struct SongGrid: View {
    var title: String
    var subtitle: String?
    var songs: [SavedSong]
    @Binding var query: String
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: LibraryUI
    var empty: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("\(songs.count)").font(.title3).foregroundStyle(.secondary)
                        }
                        if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $query).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                    .frame(width: 220)
                }
                if songs.isEmpty {
                    Text(empty).foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22)],
                          alignment: .leading, spacing: 26) {
                    ForEach(songs) { s in
                        SongCard(song: s, image: library.artwork(for: s.id), tint: settings.highlight,
                                 model: model, library: library, ui: ui)
                    }
                }
            }
            .padding(36)
        }
    }
}

/// A song tile: cover, title, artist, the app it's from in light text, and a ••• menu.
struct SongCard: View {
    var song: SavedSong
    var image: NSImage?
    var tint: Color
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var ui: LibraryUI
    var inAlbum: Album? = nil
    @Local private var over = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cover(image: image, title: song.title, tint: tint)
                .shadow(color: .black.opacity(over ? 0.28 : 0.14), radius: over ? 10 : 4, y: over ? 6 : 2)
                .overlay(alignment: .bottomLeading) {
                    if over {
                        Button { model.play(song) } label: {
                            Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black.opacity(0.85))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(.white.opacity(0.92)))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help(song.appName.map { "Play in \($0)" } ?? "Play")
                        .padding(10)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if over {
                        MenuAnchorButton(ui: ui, kind: .addToAlbum(song)) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black.opacity(0.8))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(.white.opacity(0.92)))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }
                        .help("Add to album")
                        .padding(8)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Heart: always shown once liked, otherwise only on hover.
                    let liked = library.isLiked(song.id)
                    if over || liked {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { library.toggleLike(song.id) }
                        } label: {
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(liked ? Color(hex: "#FF4F7B") : .black.opacity(0.8))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(.white.opacity(0.92)))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                .scaleEffect(liked ? 1.0 : 0.94)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .help(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
                        .padding(10)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .scaleEffect(over ? 1.03 : 1)
                .onTapGesture { ui.open(song.id) }
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(song.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if let app = song.appName {
                        Text(app).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                MenuAnchorButton(ui: ui, kind: .songActions(song, inAlbum: inAlbum)) {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .opacity(over ? 1 : 0.45)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { over = h } }
    }
}

struct PlainIcon: View {
    let name: String
    var size: CGFloat = 16
    let action: () -> Void
    init(_ name: String, size: CGFloat = 16, action: @escaping () -> Void) {
        self.name = name; self.size = size; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
                .frame(width: size + 20, height: size + 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Now Playing

struct NowPlayingPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var listener: Listener
    @Local private var pasting = false

    var body: some View {
        // The page is pinned to the window's size: the header and cards take what they need,
        // and the lyrics get whatever height is left (they can never push the header off screen).
        GeometryReader { g in
            VStack(alignment: .leading, spacing: 22) {
                header.fixedSize(horizontal: false, vertical: true)
                if let err = nowPlaying.adapterError {
                    Text(err).foregroundStyle(.red)
                }
                if model.status == .notFound {
                    NoLyricsCard(model: model, settings: settings).fixedSize(horizontal: false, vertical: true)
                }
                if model.listenStart != nil || model.listenReport != nil || listener.state != .idle {
                    ListenCard(model: model, listener: listener, settings: settings).fixedSize(horizontal: false, vertical: true)
                }
                ZStack {
                    GlassBackground(settings: settings, corner: 22)
                    LyricsStage(model: model, settings: settings, nowPlaying: nowPlaying)
                        .padding(.vertical, 16)
                }
                .frame(maxHeight: .infinity)
                .layoutPriority(-1)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
            }
            .padding(32)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .clipped()
        }
        .sheet(isPresented: $pasting) {
            PasteSheet(model: model, title: nowPlaying.track?.title ?? "", artist: nowPlaying.track?.artist ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            Group {
                if settings.showDisc {
                    Turntable(nowPlaying: nowPlaying, settings: settings)
                        .frame(width: 118, height: 154)
                } else {
                    Cover(image: nowPlaying.artwork, title: nowPlaying.track?.title ?? "♪", tint: settings.highlight, corner: 14)
                        .frame(width: 132, height: 132)
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(nowPlaying.track == nil ? "NOTHING PLAYING" : "NOW PLAYING · \(nowPlaying.track!.playerName)")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(nowPlaying.track.map { TitleCleaner.title($0.title) } ?? "Play a song in any music app")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(2)
                if let t = nowPlaying.track {
                    Text(TitleCleaner.artist(t.artist)).font(.title3).foregroundStyle(.secondary)
                }
                if let s = model.song {
                    HStack(spacing: 6) {
                        Chip(text: "\(s.source) · \(timingLabel(s.timing))", tint: settings.highlight)
                        SyncChip(sync: model.wordSync, songID: s.id, song: s, tint: settings.primary)
                    }
                } else if model.status == .searching {
                    Chip(text: "Looking for lyrics…", tint: settings.highlight)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button { model.islandShown.toggle() } label: {
                    Label(model.islandShown ? "Hide island" : "Show island", systemImage: "pip")
                }
                if nowPlaying.track != nil {
                    Button { model.retrySearch() } label: { Label("Search again", systemImage: "arrow.clockwise") }
                    Button { pasting = true } label: { Label("Paste lyrics", systemImage: "doc.on.clipboard") }
                    if model.listenStart == nil {
                        Button { model.startListening() } label: { Label("Listen", systemImage: "waveform") }
                            .help(model.song == nil ? "Write down the lyrics by listening (beta)"
                                                    : "Test how well listening works on this song")
                    }
                }
            }
            .buttonStyle(GlassButton())
        }
    }
}

/// Shows what Sync words is doing for this song.
struct SyncChip: View {
    @ObservedObject var sync: WordSync
    var songID: String
    var song: SavedSong
    var tint: Color

    var body: some View {
        let synced = song.lines.filter { $0.words != nil }.count
        Group {
            switch sync.state {
            case .recording(let id) where id == songID:
                Label("Listening to sync words", systemImage: "waveform")
            case .aligning(let id) where id == songID:
                Label("Syncing words…", systemImage: "wand.and.stars")
            default:
                if song.timing == .line, synced > 0 {
                    Label("\(synced)/\(song.lines.count) lines synced", systemImage: "checkmark.seal.fill")
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.18)))
    }
}

struct Chip: View {
    var text: String
    var tint: Color
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.22)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.4)))
    }
}

struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Shown when nothing was found online: 汽水音乐 link first, then listening, then pasting.
struct NoLyricsCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @Local private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No lyrics found online").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link.circle.fill").font(.title2).foregroundStyle(settings.highlight)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playing it in 汽水音乐? Click Share → Copy Link on the song. The lyrics come in by themselves, timed for every character.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("…or paste a 汽水音乐 link here", text: $link)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(go)
                        Button("Get lyrics", action: go)
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || model.qishuiBusy)
                    }
                    if let m = model.qishuiMessage {
                        Text(m).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(settings.highlight)
                Text("Not on 汽水音乐? Click Listen and your Mac writes the lyrics down as the song plays (beta, often wrong).")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }

    private func go() {
        let l = link
        Task { await model.importQishui(l); link = "" }
    }
}

/// Live view while listening, and the score afterwards.
struct ListenCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var listener: Listener
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: model.listenStart != nil)
                    .foregroundStyle(settings.highlight)
                Text(model.listenStart != nil ? (model.song == nil ? "Listening and writing the lyrics…"
                                                                     : "Listening test: play at least 30 seconds")
                                              : "Listening result").font(.headline)
                Spacer()
                if model.listenStart != nil {
                    Button("Stop") { model.stopListening() }.buttonStyle(GlassButton())
                }
            }
            if case .failed(let why) = listener.state {
                Text(why).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.listenStart != nil {
                Text(heardText.isEmpty ? "Waiting for singing…" : heardText)
                    .font(.system(size: 17, weight: .medium))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary.opacity(0.9))
            }
            if let r = model.listenReport {
                HStack(spacing: 26) {
                    Stat(value: pct(r.soundAccuracy), label: "sounds right")
                    Stat(value: pct(r.characterAccuracy), label: "exact characters")
                    Stat(value: r.timingError.map { String(format: "%.2fs", $0) } ?? "–", label: "timing off by")
                    Stat(value: "\(r.heardCount)/\(r.expectedCount)", label: "characters heard")
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }

    private var heardText: String {
        let done = listener.heard.suffix(24).map(\.text).joined()
        return String((done + listener.partial).suffix(40))
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

struct Stat: View {
    var value: String
    var label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

func timingLabel(_ t: Timing) -> String {
    switch t {
    case .word: return "word-by-word timing"
    case .line: return "line timing"
    case .none: return "no timing"
    }
}

// MARK: Paste

struct PasteSheet: View {
    @ObservedObject var model: AppModel
    @Local var title: String
    @Local var artist: String
    @Local private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste lyrics").font(.title2.weight(.semibold))
            Text("Paste LRC lyrics (lines that start with times like [00:12.34]) to get karaoke highlighting. Plain lyrics work too, but they won't highlight.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                TextField("Song title", text: $title)
                TextField("Artist", text: $artist)
            }
            .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.system(size: 14, design: .monospaced))
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.savePasted(text, title: title, artist: artist)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

// MARK: Song detail + pinyin editing

struct SongDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: LibraryUI
    @Local var song: SavedSong
    var back: () -> Void
    @Local private var editing: UUID?
    @Local private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: back) { Label("Saved Songs", systemImage: "chevron.left") }
                    .buttonStyle(GlassButton())
                HStack(alignment: .bottom, spacing: 22) {
                    Cover(image: library.artwork(for: song.id), title: song.title, tint: settings.highlight, corner: 14)
                        .frame(width: 150, height: 150)
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(song.title).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(song.artist).font(.title3).foregroundStyle(.secondary)
                        Chip(text: "\(song.source) · \(timingLabel(song.timing)) · \(song.lines.count) lines",
                             tint: settings.highlight)
                        if let app = song.appName {
                            Text("from \(app)").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        HStack {
                            Button { model.play(song) } label: {
                                Label(song.appName.map { "Play in \($0)" } ?? "Play", systemImage: "play.fill")
                            }
                            .buttonStyle(GlassButton())
                            MenuAnchorButton(ui: ui, kind: .addToAlbum(song)) {
                                Label("Add to Album", systemImage: "plus")
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(.ultraThinMaterial))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                                    .contentShape(Capsule())
                            }
                            MenuAnchorButton(ui: ui, kind: .songActions(song, inAlbum: nil)) {
                                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                                    .frame(width: 20, height: 16)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(.ultraThinMaterial))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                                    .contentShape(Capsule())
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                // Make it obvious that pinyin can be fixed.
                HStack(spacing: 12) {
                    Image(systemName: "pencil.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pinyin is made automatically, so it can be wrong.").fontWeight(.semibold)
                        Text("Click any line below to fix its pinyin. Your fixes are saved with the song.")
                            .font(.callout).opacity(0.85)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(settings.highlight.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.highlight.opacity(0.5)))

                HStack(spacing: 16) {
                    if song.timing != .none {
                        Stepper(value: Binding(get: { song.offset }, set: { song.offset = $0; save() }),
                                in: -10...10, step: 0.25) {
                            Text("Timing shift: \(String(format: "%+.2f", song.offset)) s")
                        }
                        .help("Lyrics too late? Shift up. Too early? Shift down.")
                    }
                    Spacer()
                }

                VStack(spacing: 0) {
                    ForEach(song.lines) { line in row(line); Divider().opacity(0.4) }
                }
            }
            .padding(32)
        }

    }

    @ViewBuilder
    private func row(_ line: LyricLine) -> some View {
        let tokens = PinyinEngine.shared.tokens(for: line, style: settings.toneStyle)
        let py = tokens.compactMap(\.pinyin)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if song.timing != .none {
                    Text(clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .leading)
                }
                Text(line.text).font(.system(size: 18, weight: .medium))
                if line.pinyinOverride != nil {
                    Text("edited").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(settings.highlight.opacity(0.25)))
                }
                Spacer()
            }
            if editing == line.id {
                HStack {
                    TextField("pinyin, one per character, separated by spaces", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, design: .rounded))
                        .onSubmit { commit(line) }
                    Button("Save") { commit(line) }.buttonStyle(.borderedProminent)
                    Button("Cancel") { editing = nil }
                    if line.pinyinOverride != nil {
                        Button("Reset") { setOverride(line, nil) }
                    }
                }
                Text("\(py.count) characters → type \(py.count) pinyin, e.g. \(py.prefix(3).joined(separator: " "))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(py.joined(separator: " "))
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, song.timing != .none ? 52 : 0)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editing != line.id else { return }
            draft = py.joined(separator: " ")
            editing = line.id
        }
    }

    private func commit(_ line: LyricLine) {
        let parts = draft.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        setOverride(line, parts.isEmpty ? nil : parts)
    }

    private func setOverride(_ line: LyricLine, _ value: [String]?) {
        if let i = song.lines.firstIndex(where: { $0.id == line.id }) {
            song.lines[i].pinyinOverride = value
            save()
        }
        editing = nil
    }

    private func save() { model.update(song) }

    private func clock(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: Customization (how it looks)

struct CustomizationView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageTitle(title: "Customization", subtitle: "Pick a look. Every theme is tuned for both the dashboard and the lyrics island.")

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle("Theme")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(Theme.all) { t in
                            ThemeCard(theme: t, selected: settings.themeID == t.id, artColor: settings.artColor) {
                                withAnimation(.easeInOut(duration: 0.5)) { settings.themeID = t.id }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle("Appearance")
                    HStack(spacing: 12) {
                        ForEach(AppearanceMode.allCases) { m in
                            AppearanceTile(mode: m, selected: settings.appearance == m, tint: settings.primary) {
                                settings.appearance = m
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle("Lyrics island")
                    VStack(spacing: 0) {
                        SettingRow("Pinyin style") {
                            ChoicePills(options: ToneStyle.allCases.map { ($0, $0.sample) },
                                        selection: Binding(get: { settings.toneStyle }, set: { settings.toneStyle = $0 }),
                                        tint: settings.primary, rounded: true)
                        }
                        RowDivider()
                        SettingRow("Show pinyin") { Toggle("", isOn: $settings.showPinyin).labelsHidden().toggleStyle(.switch) }
                        RowDivider()
                        SettingRow("Text size") {
                            HStack {
                                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                                Slider(value: $settings.fontSize, in: 18...40).frame(width: 220)
                                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                            }
                        }
                        RowDivider()
                        SettingRow("See-through") {
                            HStack {
                                Text("Solid").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $settings.glass, in: 0...1).frame(width: 200)
                                Text("Glass").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        RowDivider()
                        SettingRow("Spinning record", detail: "A record with the album art and a needle, next to the lyrics") {
                            Toggle("", isOn: $settings.showDisc).labelsHidden().toggleStyle(.switch)
                        }
                        RowDivider()
                        SettingRow("Lines with no word timing", detail: "How a line lights up when only its start time is known") {
                            ChoicePills(options: LineFill.allCases.map { ($0, $0.short) },
                                        selection: Binding(get: { settings.lineFill }, set: { settings.lineFill = $0 }),
                                        tint: settings.primary, rounded: false)
                        }
                    }
                    .glassCard(18)
                }
            }
            .padding(36)
        }
    }
}

/// A theme as a little preview: the dashboard's background, a sidebar strip, and a lyric line
/// lit in the theme's sung color on its island.
struct ThemeCard: View {
    var theme: Theme
    var selected: Bool
    var artColor: Color?
    var action: () -> Void
    @Local private var over = false

    var body: some View {
        let p = theme.followsArt ? (artColor?.vivid(brightness: 0.95) ?? Color(hex: theme.primary)) : Color(hex: theme.primary)
        let s2 = theme.followsArt ? (artColor?.vivid(brightness: 0.6, hueShift: 30) ?? Color(hex: theme.secondary)) : Color(hex: theme.secondary)
        let hl = theme.followsArt ? (artColor?.vivid(brightness: 1, saturation: 0.55) ?? Color(hex: theme.highlight)) : Color(hex: theme.highlight)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    ZStack {
                        Color(white: 0.08)
                        Circle().fill(p.opacity(0.55)).frame(width: 150).blur(radius: 40).offset(x: -60, y: -40)
                        Circle().fill(s2.opacity(0.5)).frame(width: 140).blur(radius: 40).offset(x: 70, y: 30)
                    }
                    HStack(spacing: 0) {
                        Rectangle().fill(.white.opacity(0.06)).frame(width: 34)
                        Spacer()
                    }
                    VStack(spacing: 2) {
                        (Text("音乐").foregroundColor(hl) + Text("好听").foregroundColor(.white))
                            .font(.system(size: 13, weight: .bold))
                        Text("yīn yuè hǎo tīng").font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: theme.island).opacity(0.85)))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? p : .white.opacity(0.1), lineWidth: selected ? 2.5 : 1))
                HStack {
                    Text(theme.name).font(.system(size: 14, weight: .semibold))
                    if theme.followsArt {
                        Text("follows the song").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(p)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(10)
            .glassCard(18)
            .scaleEffect(over ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: over)
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

struct AppearanceTile: View {
    var mode: AppearanceMode
    var selected: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: mode == .light ? "sun.max.fill" : mode == .dark ? "moon.fill" : "circle.lefthalf.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? tint : .secondary)
                Text(mode.label).font(.system(size: 13, weight: .medium))
            }
            .frame(width: 120, height: 82)
            .glassCard(16)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? tint : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// A small row of pills to pick one option. Compact, so it fits next to its label.
struct ChoicePills<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    var tint: Color
    var rounded: Bool
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = value }
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: on ? .semibold : .medium, design: rounded ? .rounded : .default))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background {
                            if on {
                                Capsule().fill(tint).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct PageTitle: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 34, weight: .heavy, design: .rounded))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
    }
}

struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 20, weight: .bold, design: .rounded))
    }
}

/// A settings row: title (and detail) on the left, wrapping as needed, and the control on the right
/// at its natural size, so nothing spills out of the card.
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.control = control()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            labels.frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.07)).frame(height: 1).padding(.leading, 18) }
}

// MARK: Settings (how it behaves)

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// Slider value not applied yet.
    @Local private var draftLead: Double?

    private func applyLead() {
        guard let v = draftLead else { return }
        settings.leadTime = v
        settings.objectWillChange.send()
        draftLead = nil
        model.notify("Lyrics timing applied", detail: String(format: "Words now light up %+.2f s early", v))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageTitle(title: "Settings")

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle("Timing")
                    VStack(spacing: 0) {
                        SettingRow("Light up earlier by", detail: "Applies right away, to the song playing now and every song after.") {
                            HStack(spacing: 10) {
                                Slider(value: Binding(get: { draftLead ?? settings.leadTime }, set: { draftLead = $0 }),
                                       in: -0.5...0.8, step: 0.05).frame(width: 180)
                                Text(String(format: "%+.2f s", draftLead ?? settings.leadTime))
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(width: 56)
                                Button("Apply") { applyLead() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(draftLead == nil || draftLead == settings.leadTime)
                            }
                        }
                        RowDivider()
                        SettingRow("Sync words to the singing",
                                   detail: WordSync.isInstalled
                                       ? "Records line-timed songs once (only the music app's sound), finds when every character is sung, then deletes the recording."
                                       : "Needs the sync tools. See the README.") {
                            Toggle("", isOn: $settings.syncWords).labelsHidden().toggleStyle(.switch)
                                .disabled(!WordSync.isInstalled)
                        }
                    }
                    .glassCard(18)
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle("Lyrics island")
                    VStack(spacing: 0) {
                        SettingRow("Keep it on top of other windows", detail: "Off: it acts like a normal window and goes behind whatever you click.") {
                            Toggle("", isOn: $settings.alwaysOnTop).labelsHidden().toggleStyle(.switch)
                        }
                        RowDivider()
                        SettingRow("Show it on every desktop", detail: "Off: it stays on the desktop it's on.") {
                            Toggle("", isOn: $settings.allSpaces).labelsHidden().toggleStyle(.switch)
                        }
                        RowDivider()
                        SettingRow("Position") {
                            Button("Move to bottom-center") { model.resetIsland() }
                        }
                    }
                    .glassCard(18)
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle("Feedback")
                    FeedbackForm(model: model, settings: settings)
                }
            }
            .padding(36)
        }
    }
}

/// Where to send ideas and bug reports: a message on LinkedIn, or an issue on GitHub.
struct FeedbackForm: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(LinearGradient(colors: [settings.primary, settings.secondary],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Have an idea or found a bug?").font(.system(size: 15, weight: .semibold))
                    Text("Message the developer on LinkedIn, or report it on GitHub so others can see it too.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if let url = FeedbackLinks.linkedIn {
                    DialogButton("Message on LinkedIn", settings: settings, style: .primary, symbol: "person.crop.circle.fill") {
                        NSWorkspace.shared.open(url)
                    }
                }
                DialogButton("Report on GitHub", settings: settings, style: .tinted, symbol: "ladybug.fill") {
                    NSWorkspace.shared.open(FeedbackLinks.githubIssues)
                }
            }
        }
        .padding(18)
        .glassCard(18)
    }
}

enum FeedbackLinks {
    /// The developer's LinkedIn profile.
    static let linkedIn = URL(string: "https://www.linkedin.com/in/yue-chen-0aa274317/")
    static let githubIssues = URL(string: "https://github.com/Astribus/yues-yinyue/issues/new")!
}
