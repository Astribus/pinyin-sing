import SwiftUI

// Our own menus and dialogs, drawn in the app's theme instead of the system's.
// Everything is shown by `PopupHost`, an overlay on the whole dashboard, so a menu is
// never clipped by the grid or scroll view it was opened from.

/// What a menu is about, and where it was opened (in the dashboard's coordinates).
struct PopupState: Equatable {
    enum Kind: Hashable {
        case songActions(SavedSong, inAlbum: Album?)
        case addToAlbum(SavedSong)
        case albumActions(Album)
    }
    var kind: Kind
    var anchor: CGRect
}

/// Name of the coordinate space that menu anchors are measured in.
let dashSpace = "dashboard"

/// A button that opens one of our menus right under itself.
struct MenuAnchorButton<Label: View>: View {
    @ObservedObject var ui: LibraryUI
    var kind: PopupState.Kind
    @ViewBuilder var label: Label
    @Local private var frame: CGRect = .zero

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                ui.popup = PopupState(kind: kind, anchor: frame)
            }
        } label: { label }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { frame = g.frame(in: .named(dashSpace)) }
                .onChange(of: g.frame(in: .named(dashSpace))) { _, f in frame = f }
        })
    }
}

/// Draws whichever menu or dialog is open, over the whole dashboard.
struct PopupHost: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: LibraryUI

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if let p = ui.popup {
                    // Click anywhere else to close.
                    Color.black.opacity(0.001)
                        .onTapGesture { close() }
                    menu(p)
                        .fixedSize()
                        .alignmentGuide(.leading) { d in -placeX(p.anchor, width: d.width, in: g.size) }
                        .alignmentGuide(.top) { d in -placeY(p.anchor, height: d.height, in: g.size) }
                        .transition(.scale(scale: 0.88, anchor: .topTrailing).combined(with: .opacity))
                        .id(p.kind)
                }
                if let modal = activeModal {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { dismissModal() }
                        .transition(.opacity)
                    modal
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: ui.popup)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: modalKey)
    }

    private func close() { ui.popup = nil }

    // Right-aligned under the button; flipped above it when there's no room below.
    private func placeX(_ a: CGRect, width: CGFloat, in size: CGSize) -> CGFloat {
        min(max(12, a.maxX - width), size.width - width - 12)
    }
    private func placeY(_ a: CGRect, height: CGFloat, in size: CGSize) -> CGFloat {
        let below = a.maxY + 6
        return below + height > size.height - 12 ? max(12, a.minY - height - 6) : below
    }

    @ViewBuilder
    private func menu(_ p: PopupState) -> some View {
        switch p.kind {
        case .songActions(let song, let album):
            MenuCard(settings: settings) {
                MenuRow("play.fill", song.appName.map { "Play in \($0)" } ?? "Play", settings) { close(); model.play(song) }
                MenuRow("quote.bubble.fill", "Lyrics & Pinyin", settings) { close(); ui.open(song.id) }
                MenuRow(library.isLiked(song.id) ? "heart.slash.fill" : "heart.fill",
                        library.isLiked(song.id) ? "Remove from Liked Songs" : "Add to Liked Songs", settings) {
                    close(); library.toggleLike(song.id)
                }
                MenuRow("plus.square.on.square", "Add to Album…", settings, chevron: true) {
                    ui.popup = PopupState(kind: .addToAlbum(song), anchor: p.anchor)
                }
                if let album, album.id != LyricsLibrary.likedID {
                    MenuRow("minus.circle", "Remove from \(album.name)", settings) {
                        close(); library.remove(song.id, from: album.id)
                    }
                }
                MenuDivider()
                MenuRow("pencil", "Edit Title & Artist…", settings) { close(); ui.editing = song }
                MenuRow("trash", "Delete…", settings, destructive: true) { close(); ui.deleting = song }
            }
        case .addToAlbum(let song):
            AlbumPicker(library: library, settings: settings, song: song) { close() }
        case .albumActions(let album):
            MenuCard(settings: settings) {
                MenuRow("pencil", "Rename…", settings) { close(); ui.renamingAlbum = album }
                MenuRow("trash", "Delete Album", settings, destructive: true) {
                    close()
                    ui.page = .home
                    library.deleteAlbum(album.id)
                }
            }
        }
    }

    // MARK: Dialogs

    private var modalKey: String {
        if ui.namingAlbum != nil { return "new" }
        if ui.renamingAlbum != nil { return "rename" }
        if ui.editing != nil { return "edit" }
        if ui.deleting != nil { return "delete" }
        if model.choosingApp != nil { return "app" }
        return ""
    }

    private func dismissModal() {
        ui.namingAlbum = nil
        ui.renamingAlbum = nil
        ui.editing = nil
        ui.deleting = nil
        model.choosingApp = nil
    }

    private var activeModal: AnyView? {
        if let req = ui.namingAlbum {
            let song = req.songID.flatMap { id in library.songs.first { $0.id == id } }
            return AnyView(NewAlbumDialog(settings: settings, library: library, song: song) { name in
                let a = library.newAlbum(name, with: req.songID)
                if req.songID == nil { ui.page = .album(a.id) }
                model.notify("Album created", detail: song.map { "\(name) · added \($0.title)" } ?? name)
                dismissModal()
            } cancel: { dismissModal() })
        }
        if let a = ui.renamingAlbum {
            return AnyView(TextDialog(settings: settings, icon: "pencil", title: "Rename album",
                                      placeholder: "Album name", initial: a.name, action: "Save", note: nil) { name in
                library.renameAlbum(a.id, to: name)
                dismissModal()
            } cancel: { dismissModal() })
        }
        if let s = ui.editing {
            return AnyView(EditDialog(model: model, settings: settings, song: s) { dismissModal() })
        }
        if let s = ui.deleting {
            return AnyView(ThemedDialog(settings: settings, icon: "trash", tint: .red, title: "Delete \(s.title)?",
                                        message: "Its saved lyrics and pinyin fixes are removed. If you play it again, the lyrics are searched for again.") {
                HStack(spacing: 10) {
                    DialogButton("Cancel", settings: settings, style: .plain) { dismissModal() }
                    DialogButton("Delete", settings: settings, style: .destructive) {
                        if ui.openSong == s.id { ui.openSong = nil }
                        model.delete(s)
                        dismissModal()
                    }
                }
            })
        }
        if let s = model.choosingApp {
            return AnyView(ThemedDialog(settings: settings, icon: "play.circle.fill", tint: settings.primary,
                                        title: "Open \(s.title) in…",
                                        message: "This song was saved before the app remembered where it was played. Your choice is saved with the song.") {
                VStack(spacing: 8) {
                    ForEach(Player.choosablePlatforms, id: \.self) { app in
                        DialogButton(Platform.name(app), settings: settings, style: .tinted,
                                     symbol: Platform.symbol(app)) {
                            dismissModal()
                            model.play(s, in: app)
                        }
                    }
                    DialogButton("Cancel", settings: settings, style: .plain) { dismissModal() }
                }
            })
        }
        return nil
    }
}

// MARK: Menu pieces

struct MenuCard<Content: View>: View {
    @ObservedObject var settings: AppSettings
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(6)
            .frame(minWidth: 230, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [settings.primary.opacity(0.14), settings.secondary.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(settings.primary.opacity(0.25)))
            .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
    }
}

struct MenuRow: View {
    let symbol: String
    let title: String
    @ObservedObject var settings: AppSettings
    var destructive = false
    var chevron = false
    var checked = false
    let action: () -> Void
    @Local private var over = false

    init(_ symbol: String, _ title: String, _ settings: AppSettings, destructive: Bool = false,
         chevron: Bool = false, checked: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.title = title; self.settings = settings
        self.destructive = destructive; self.chevron = chevron; self.checked = checked; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(destructive ? Color.red : settings.primary)
                    .frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(settings.primary)
                }
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((destructive ? Color.red : settings.primary).opacity(over ? 0.18 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { over = h } }
    }
}

struct MenuDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
    }
}

/// "Add to album": create a new one (with the song in it) at the top, then every album
/// with a check on the ones the song is already in. Clicking an album adds or removes it.
struct AlbumPicker: View {
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    var song: SavedSong
    var done: () -> Void
    @Local private var creating = false
    @Local private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        MenuCard(settings: settings) {
            Text("ADD TO ALBUM")
                .font(.system(size: 10, weight: .bold)).tracking(1.1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            if creating {
                HStack(spacing: 8) {
                    TextField("New album name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($focused)
                        .onSubmit(create)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(settings.primary.opacity(0.5)))
                    Button(action: create) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(settings.primary))
                    }
                    .buttonStyle(.plain)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .onAppear { focused = true }
            } else {
                MenuRow("plus", "Create new album", settings) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { creating = true }
                }
            }
            MenuDivider()
            ForEach(library.albums) { a in
                let inIt = a.songIDs.contains(song.id)
                CheckRow(symbol: a.id == LyricsLibrary.likedID ? "heart.fill" : "square.stack.fill",
                         title: a.name, checked: inIt, settings: settings) {
                    if inIt { library.remove(song.id, from: a.id) } else { library.add(song.id, to: a.id) }
                }
            }
        }
        .frame(width: 260)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        library.newAlbum(n, with: song.id)
        done()
    }
}

/// An album row with a real checkbox: an outlined rounded square, filled with the theme
/// color and a white check when the song is in that album.
struct CheckRow: View {
    var symbol: String
    var title: String
    var checked: Bool
    @ObservedObject var settings: AppSettings
    var action: () -> Void
    @Local private var over = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { action() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(checked ? settings.primary : Color.primary.opacity(over ? 0.08 : 0.03))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(checked ? settings.primary : Color.primary.opacity(0.3), lineWidth: 1.5)
                    if checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(width: 18, height: 18)
                .scaleEffect(checked ? 1 : 0.94)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(settings.primary.opacity(0.85))
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(settings.primary.opacity(over ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { over = h } }
    }
}

// MARK: Dialog pieces

struct ThemedDialog<Buttons: View>: View {
    @ObservedObject var settings: AppSettings
    var icon: String
    var tint: Color
    var title: String
    var message: String?
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(tint.opacity(0.16)))
            Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            buttons.padding(.top, 4)
        }
        .padding(26)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75)))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [settings.primary.opacity(0.16), settings.secondary.opacity(0.08)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(settings.primary.opacity(0.28)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
    }
}

struct DialogButton: View {
    enum Style { case primary, plain, destructive, tinted }
    let title: String
    @ObservedObject var settings: AppSettings
    var style: Style
    var symbol: String?
    var disabled = false
    let action: () -> Void
    @Local private var over = false

    init(_ title: String, settings: AppSettings, style: Style, symbol: String? = nil, disabled: Bool = false,
         action: @escaping () -> Void) {
        self.title = title; self.settings = settings; self.style = style; self.symbol = symbol
        self.disabled = disabled; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(style == .plain ? Color.primary.opacity(0.12) : .clear))
            .scaleEffect(over && !disabled ? 1.02 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { over = h } }
    }

    private var fg: Color {
        if disabled { return .secondary }
        switch style {
        case .primary, .destructive: return .white
        case .plain: return .primary
        case .tinted: return settings.primary
        }
    }
    private var bg: Color {
        if disabled { return Color.primary.opacity(0.08) }
        switch style {
        case .primary: return settings.primary.opacity(over ? 1 : 0.9)
        case .destructive: return Color.red.opacity(over ? 0.95 : 0.85)
        case .plain: return Color.primary.opacity(over ? 0.1 : 0.05)
        case .tinted: return settings.primary.opacity(over ? 0.24 : 0.15)
        }
    }
}

struct ThemedField: View {
    var placeholder: String
    @Binding var text: String
    @ObservedObject var settings: AppSettings
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? settings.primary.opacity(0.7) : .primary.opacity(0.1), lineWidth: focused ? 1.5 : 1))
            .onAppear { focused = true }
    }
}

struct TextDialog: View {
    @ObservedObject var settings: AppSettings
    var icon: String
    var title: String
    var placeholder: String
    var initial: String
    var action: String
    var note: String?
    var done: (String) -> Void
    var cancel: () -> Void
    @Local private var text = ""

    var body: some View {
        ThemedDialog(settings: settings, icon: icon, tint: settings.primary, title: title, message: note) {
            VStack(spacing: 12) {
                ThemedField(placeholder: placeholder, text: $text, settings: settings, onSubmit: save)
                HStack(spacing: 10) {
                    DialogButton("Cancel", settings: settings, style: .plain, action: cancel)
                    DialogButton(action, settings: settings, style: .primary, disabled: trimmed.isEmpty, action: save)
                }
            }
        }
        .onAppear { text = initial }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    private func save() { if !trimmed.isEmpty { done(trimmed) } }
}

struct EditDialog: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @Local var song: SavedSong
    var close: () -> Void

    var body: some View {
        ThemedDialog(settings: settings, icon: "pencil", tint: settings.primary, title: "Edit song",
                     message: "This only changes how it's shown here. The song is still recognized when it plays.") {
            VStack(spacing: 10) {
                ThemedField(placeholder: "Title", text: $song.title, settings: settings, onSubmit: save)
                ThemedField(placeholder: "Artist", text: $song.artist, settings: settings, onSubmit: save)
                HStack(spacing: 10) {
                    DialogButton("Cancel", settings: settings, style: .plain, action: close)
                    DialogButton("Save", settings: settings, style: .primary,
                                 disabled: song.title.trimmingCharacters(in: .whitespaces).isEmpty, action: save)
                }
                .padding(.top, 2)
            }
        }
    }

    private func save() {
        guard !song.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.update(song)
        close()
    }
}

/// "New album": a live cover preview that updates as you type, the name field, and (when it was
/// opened from a song) that song's cover and title so it's clear what's being added.
struct NewAlbumDialog: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LyricsLibrary
    var song: SavedSong?
    var done: (String) -> Void
    var cancel: () -> Void
    @Local private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                // Cover preview: the first letter of the name on the theme's gradient.
                ZStack {
                    LinearGradient(colors: [settings.primary, settings.secondary],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let first = trimmed.first {
                        Text(String(first))
                            .font(.system(size: 46, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .id(first)
                    } else {
                        Image(systemName: "square.stack.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.2)))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: trimmed.first)

                VStack(alignment: .leading, spacing: 6) {
                    Text("NEW ALBUM").font(.system(size: 11, weight: .bold)).tracking(1.3)
                        .foregroundStyle(settings.primary)
                    Text(trimmed.isEmpty ? "Untitled" : trimmed)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(2)
                        .animation(nil, value: trimmed)
                    Text(song == nil ? "Empty for now" : "1 song")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            ThemedField(placeholder: "Album name", text: $name, settings: settings, onSubmit: save)

            if let song {
                HStack(spacing: 12) {
                    Cover(image: library.artwork(for: song.id), title: song.title, tint: settings.primary, corner: 8)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Adding").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(settings.primary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(settings.primary.opacity(0.12)))
            }

            HStack(spacing: 10) {
                DialogButton("Cancel", settings: settings, style: .plain, action: cancel)
                DialogButton("Create album", settings: settings, style: .primary, symbol: "plus",
                             disabled: trimmed.isEmpty, action: save)
            }
        }
        .padding(26)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.8)))
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial))
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(LinearGradient(colors: [settings.primary.opacity(0.22), settings.secondary.opacity(0.1)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(settings.primary.opacity(0.35), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private func save() { if !trimmed.isEmpty { done(trimmed) } }
}
