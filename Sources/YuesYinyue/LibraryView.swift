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
        NavigationSplitView {
            sidebar
        } detail: {
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
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(settings.primary)
        .onChange(of: ui.page) { ui.openSong = nil }
        .onReceive(NotificationCenter.default.publisher(for: .init("debugPage"))) { _ in ui.page = .nowPlaying }
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

    private var sidebar: some View {
        List(selection: $ui.page) {
            Text("音乐")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [settings.primary, settings.secondary],
                                                startPoint: .leading, endPoint: .trailing))
                .padding(.vertical, 4)
                .selectionDisabled()
            Label("Home", systemImage: "house.fill").tag(LibraryUI.Page.home)
            Label("Now Playing", systemImage: "play.circle.fill").tag(LibraryUI.Page.nowPlaying)

            Section("Library") {
                Label("All Songs", systemImage: "music.note.list")
                    .badge(library.songs.count)
                    .tag(LibraryUI.Page.songs(app: nil))
                ForEach(apps, id: \.self) { app in
                    Label(Track.name(forBundle: app), systemImage: AppIcon.symbol(app))
                        .badge(library.songs.filter { $0.app == app }.count)
                        .tag(LibraryUI.Page.songs(app: app))
                }
            }

            Section("Albums") {
                ForEach(library.albums) { a in
                    Label(a.name, systemImage: a.id == LyricsLibrary.likedID ? "heart.fill" : "square.stack.fill")
                        .badge(a.songIDs.count)
                        .tag(LibraryUI.Page.album(a.id))
                }
                Button { ui.namingAlbum = .init(songID: nil) } label: {
                    Label("New Album", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .selectionDisabled()
            }

            Section("App") {
                Label("Customization", systemImage: "paintpalette.fill").tag(LibraryUI.Page.customize)
                Label("Settings", systemImage: "gearshape.fill").tag(LibraryUI.Page.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                SidebarButton(symbol: "arrow.down.to.line.compact", title: "Move island to bottom-center",
                              on: false, tint: settings.primary) { model.resetIsland() }
                SidebarButton(symbol: settings.allSpaces ? "square.on.square" : "square",
                              title: settings.allSpaces ? "Island on every desktop" : "Island on this desktop only",
                              on: settings.allSpaces, tint: settings.primary) { settings.allSpaces.toggle() }
                SidebarButton(symbol: settings.alwaysOnTop ? "pin.fill" : "pin.slash",
                              title: settings.alwaysOnTop ? "Island always on top" : "Island acts like a normal window",
                              on: settings.alwaysOnTop, tint: settings.primary) { settings.alwaysOnTop.toggle() }
                IslandSwitch(model: model, settings: settings)
            }
            .padding(10)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    }

    /// Apps that songs were played from, most songs first.
    private var apps: [String] {
        let counts = Dictionary(grouping: library.songs.compactMap(\.app), by: { $0 }).mapValues(\.count)
        // Fixed order (most songs first, then by name) so rows never swap places on redraw.
        return counts.keys.sorted {
            counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : Track.name(forBundle: $0) < Track.name(forBundle: $1)
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

/// The dashboard background, in the theme's style. The album art style blurs what's playing,
/// like Apple Music. Everything is drawn in overlays and clipped, so a huge or oddly shaped
/// image can never push the page's content off screen.
struct ArtBackdrop: View {
    var image: NSImage?
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = settings.primary, s2 = settings.secondary
        let dark = scheme == .dark
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                switch settings.themeStyle {
                case .albumArt:
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .blur(radius: 80).saturation(1.4).opacity(dark ? 0.7 : 0.55)
                            .transition(.opacity)
                    } else {
                        aurora(p, s2, dark ? 0.35 : 0.28)
                    }
                case .aurora:
                    aurora(p, s2, dark ? 0.5 : 0.38)
                case .gradient:
                    LinearGradient(colors: [p.opacity(dark ? 0.55 : 0.4), s2.opacity(dark ? 0.45 : 0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                case .solid:
                    p.opacity(dark ? 0.28 : 0.16)
                case .minimal:
                    Color.clear
                }
            }
            .overlay(LinearGradient(colors: dark ? [.black.opacity(0.05), .black.opacity(0.4)]
                                                 : [.white.opacity(0.0), .white.opacity(0.35)],
                                    startPoint: .top, endPoint: .bottom))
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: image)
            .animation(.easeInOut(duration: 0.4), value: settings.themeStyleRaw)
    }

    private func aurora(_ a: Color, _ b: Color, _ strength: Double) -> some View {
        GeometryReader { g in
            ZStack {
                Circle().fill(a.opacity(strength)).frame(width: g.size.width * 0.8)
                    .position(x: g.size.width * 0.15, y: g.size.height * 0.1)
                Circle().fill(b.opacity(strength)).frame(width: g.size.width * 0.7)
                    .position(x: g.size.width * 0.9, y: g.size.height * 0.45)
                Circle().fill(a.mix(b, 0.5).opacity(strength * 0.7)).frame(width: g.size.width * 0.6)
                    .position(x: g.size.width * 0.35, y: g.size.height * 1.0)
            }
            .blur(radius: 90)
        }
    }
}

// MARK: Home

struct HomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var ui: LibraryUI

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .foregroundStyle(.secondary)
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
        .background(ArtBackdrop(image: nowPlaying.artwork, settings: settings))
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Late night listening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private var hero: some View {
        HStack(spacing: 24) {
            Group {
                if settings.showDisc {
                    Turntable(nowPlaying: nowPlaying, settings: settings)
                } else {
                    Cover(image: nowPlaying.artwork, title: nowPlaying.track?.title ?? "♪", tint: settings.highlight, corner: 14)
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                }
            }
            .frame(width: settings.showDisc ? 130 : 150, height: settings.showDisc ? 169 : 150)

            VStack(alignment: .leading, spacing: 8) {
                Text(nowPlaying.track == nil ? "NOTHING PLAYING" : "NOW PLAYING")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Text(nowPlaying.track.map { TitleCleaner.title($0.title) } ?? "Play a song in any music app")
                    .font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(2)
                if let t = nowPlaying.track {
                    Text(TitleCleaner.artist(t.artist)).font(.title3).foregroundStyle(.secondary)
                    Text("from \(t.playerName)").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    if nowPlaying.track != nil {
                        HStack(spacing: 4) {
                            PlainIcon("backward.fill") { nowPlaying.send(.previous) }
                            PlainIcon(nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 22) { nowPlaying.send(.togglePlayPause) }
                            PlainIcon("forward.fill") { nowPlaying.send(.next) }
                        }
                        Button { ui.page = .nowPlaying } label: { Label("Lyrics", systemImage: "quote.bubble.fill") }
                            .buttonStyle(GlassButton())
                    }
                    Button { model.islandShown.toggle() } label: {
                        Label(model.islandShown ? "Hide island" : "Show island", systemImage: "pip")
                    }
                    .buttonStyle(GlassButton())
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private var stats: some View {
        HStack(spacing: 14) {
            StatTile(value: "\(library.songs.count)", label: "songs saved", symbol: "music.note")
            StatTile(value: "\(characters)", label: "different characters in your songs", symbol: "character.textbox.zh")
            StatTile(value: "\(Set(library.songs.compactMap(\.app)).count)", label: "apps you listen in", symbol: "square.grid.2x2.fill")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
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
                        HStack(alignment: .top, spacing: 20) {
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
        .background(ArtBackdrop(image: songs.first.flatMap { library.artwork(for: $0.id) }, settings: settings))
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
                .shadow(color: .black.opacity(over ? 0.35 : 0.18), radius: over ? 14 : 6, y: over ? 8 : 3)
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
        .background(ArtBackdrop(image: nowPlaying.artwork, settings: settings))
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
                    Chip(text: "\(s.source) · \(timingLabel(s.timing))", tint: settings.highlight)
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
        .background(ArtBackdrop(image: library.artwork(for: song.id), settings: settings))

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
        Form {
            Section("Appearance") {
                Picker("Mode", selection: Binding(get: { settings.appearance }, set: { settings.appearance = $0 })) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(ThemePreset.all) { p in
                            ThemeSwatch(preset: p, selected: isCurrent(p)) { settings.apply(p) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Picker("Style", selection: Binding(get: { settings.themeStyle }, set: { settings.themeStyle = $0 })) {
                    ForEach(ThemeStyle.allCases) { Text($0.label).tag($0) }
                }
                ColorPicker("Primary color", selection: Binding(get: { settings.primary }, set: { settings.primary = $0 }),
                            supportsOpacity: false)
                Toggle("Pick a second color myself", isOn: $settings.themeUseSecondary)
                if settings.themeUseSecondary {
                    ColorPicker("Secondary color", selection: Binding(get: { settings.secondary },
                                                                     set: { settings.secondary = $0 }),
                                supportsOpacity: false)
                } else {
                    HStack {
                        Text("Secondary color")
                        Spacer()
                        Circle().fill(settings.secondary).frame(width: 20, height: 20)
                        Text("made from the primary").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("The theme colors the dashboard. The island has its own colors below.")
                    .foregroundStyle(.secondary)
            }
            Section("Island colors") {
                ColorPicker("Sung words turn", selection: Binding(get: { settings.highlight },
                                                                  set: { settings.highlight = $0 }),
                            supportsOpacity: false)
                ColorPicker("Island color", selection: Binding(get: { settings.background },
                                                               set: { settings.background = $0 }),
                            supportsOpacity: false)
                HStack {
                    Text("Solid")
                    Slider(value: $settings.glass, in: 0...1)
                    Text("Glass")
                }
            }
            Section("Lyrics") {
                Picker("Pinyin", selection: Binding(get: { settings.toneStyle }, set: { settings.toneStyle = $0 })) {
                    ForEach(ToneStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show pinyin", isOn: $settings.showPinyin)
                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: 16...44)
                    Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 28)
                }
                Picker("Songs with only line timing", selection: Binding(get: { settings.lineFill },
                                                                       set: { settings.lineFill = $0 })) {
                    ForEach(LineFill.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Spinning record", isOn: $settings.showDisc)
            } footer: {
                Text("A record with the album art and a needle arm, next to the lyrics and on the Now Playing page. Drag the thin line on the island to make it bigger or smaller.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

extension CustomizationView {
    func isCurrent(_ p: ThemePreset) -> Bool {
        settings.themeStyle == p.style && settings.themePrimaryHex == p.primary
            && (p.secondary == nil ? !settings.themeUseSecondary : settings.themeSecondaryHex == p.secondary)
    }
}

/// A preset theme: a small preview card of its colors and style.
struct ThemeSwatch: View {
    var preset: ThemePreset
    var selected: Bool
    var action: () -> Void

    var body: some View {
        let p = Color(hex: preset.primary)
        let s = preset.secondary.map(Color.init(hex:)) ?? p.mix(.black, 0.35)
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(preset.style == .minimal ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                          : AnyShapeStyle(LinearGradient(colors: [p, s], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(alignment: .bottomLeading) {
                        if preset.style == .albumArt {
                            Image(systemName: "photo.fill").foregroundStyle(.white.opacity(0.85)).padding(7)
                        }
                    }
                    .frame(width: 74, height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .white.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                Text(preset.name).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }
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
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Light up earlier by")
                        Slider(value: Binding(get: { draftLead ?? settings.leadTime }, set: { draftLead = $0 }),
                               in: -0.5...0.8, step: 0.05)
                        Text(String(format: "%+.2f s", draftLead ?? settings.leadTime)).monospacedDigit().frame(width: 62)
                        Button("Apply") { applyLead() }
                            .buttonStyle(.borderedProminent)
                            .disabled(draftLead == nil || draftLead == settings.leadTime)
                    }
                    Text("Applies right away, to the song playing now and every song after.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } footer: {
                Text("If words light up after they're sung, slide right. Too early, slide left. Each song also has its own timing shift on its lyrics page.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep the lyrics island on top of other windows", isOn: $settings.alwaysOnTop)
            } footer: {
                Text("Off: the island acts like a normal window and goes behind whatever you click. The pin button on the island switches this too.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show the lyrics island on every desktop", isOn: $settings.allSpaces)
            } footer: {
                Text("Off: the island stays on the desktop it's on, and you'll only see it when you switch back there.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Move the lyrics island back to bottom-center") { model.resetIsland() }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
