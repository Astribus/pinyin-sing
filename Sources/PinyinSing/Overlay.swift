import AppKit
import SwiftUI

/// The floating lyrics window: stays above other apps, starts bottom-center,
/// can be dragged and resized. Clicks do NOT pass through it.
final class OverlayPanel: NSPanel {
    init(content: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 250),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        setAllSpaces(true)
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        minSize = NSSize(width: 320, height: 110)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host

        if !setFrameUsingName("LyricsOverlay") { moveToBottomCenter() }
        setFrameAutosaveName("LyricsOverlay")
    }

    override var canBecomeKey: Bool { true }

    /// true = shows on every desktop (Space); false = stays on the desktop it's on.
    func setAllSpaces(_ all: Bool) {
        collectionBehavior = all ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                                 : [.managed, .fullScreenAuxiliary]
    }

    /// true = stays above every window; false = behaves like a normal window and
    /// goes behind whatever you click next.
    func setOnTop(_ onTop: Bool) {
        let target: NSWindow.Level = onTop ? .floating : .normal
        guard level != target else { return }
        level = target
        isFloatingPanel = onTop
        orderFrontRegardless()
    }

    func moveToBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = NSSize(width: 640, height: 250)
        setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 70, width: size.width, height: size.height),
                 display: true, animate: true)
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var openLibrary: () -> Void
    var hide: () -> Void
    @Local private var hovering = false
    /// The album picker opened from the island's + button.
    @Local private var pickingAlbum = false

    var body: some View {
        ZStack {
            GlassBackground(settings: settings)
            // Grab anywhere on the island to move it (buttons still click normally).
            WindowDragArea()
            // Lines are clickable (jump there); the space around them still drags the island.
            GeometryReader { g in
                HStack(spacing: 0) {
                    if settings.showDisc {
                        // The record grows with the island and with the split handle.
                        Turntable(nowPlaying: model.nowPlaying, settings: settings)
                            .padding(.vertical, 14)
                            .padding(.leading, 18)
                            .padding(.trailing, 6)
                            .frame(width: g.size.width * settings.discSplit)
                            .allowsHitTesting(false)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        SplitHandle(fraction: $settings.discSplit, totalWidth: g.size.width)
                    }
                    LyricsStage(model: model, settings: settings, nowPlaying: model.nowPlaying)
                        .padding(.vertical, 12)
                }
                .frame(height: g.size.height)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: settings.showDisc)
            }
            // Controls only show while the pointer is on the island.
            VStack {
                HStack(spacing: 8) {
                    // Like and add-to-album for the song that's playing (once it's saved).
                    if let song = model.song {
                        IslandSongButtons(library: model.library, settings: settings, song: song,
                                          shown: hovering || pickingAlbum, picking: $pickingAlbum)
                    }
                    Spacer()
                    Bubble(shown: hovering, order: 0) {
                        RoundIcon(settings.alwaysOnTop ? "pin.fill" : "pin",
                                  help: settings.alwaysOnTop ? "Always on top (click to act like a normal window)"
                                                             : "Normal window (click to keep it on top)",
                                  active: settings.alwaysOnTop, tint: settings.highlight) {
                            settings.alwaysOnTop.toggle()
                        }
                    }
                    Bubble(shown: hovering, order: 1) {
                        RoundIcon("books.vertical", help: "Library & settings", action: openLibrary)
                    }
                    Bubble(shown: hovering, order: 2) {
                        RoundIcon("xmark", help: "Hide (bring back from the menu bar)", action: hide)
                    }
                }
                Spacer()
                Bubble(shown: hovering, order: 0) {
                    SeekBar(nowPlaying: model.nowPlaying, tint: settings.highlight)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)
                }
                PlayerControls(model: model, nowPlaying: model.nowPlaying, settings: settings, shown: hovering)
            }
            .padding(10)
            // Album picker, right on the island. Click outside it to close.
            if pickingAlbum, let song = model.song {
                Color.black.opacity(0.25)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pickingAlbum = false } }
                    .transition(.opacity)
                GeometryReader { g in
                    ScrollView(showsIndicators: false) {
                        AlbumPicker(library: model.library, settings: settings, song: song) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pickingAlbum = false }
                        }
                    }
                    .frame(width: 260, height: min(g.size.height - 20, 320))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
                }
                .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { hovering = h } }
    }
}

/// Pops a control in and out like a bubble, one after another.
struct Bubble<Content: View>: View {
    var shown: Bool
    var order: Int
    @ViewBuilder var content: Content

    var body: some View {
        content
            .scaleEffect(shown ? 1 : 0.4)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 4)
            .animation(.spring(response: 0.38, dampingFraction: 0.62).delay(shown ? Double(order) * 0.035 : 0),
                       value: shown)
            .allowsHitTesting(shown)
    }
}

/// Previous · play/pause · next, plus a speed button that opens into a slider.
struct PlayerControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var settings: AppSettings
    var shown: Bool
    @Local private var speedOpen = false
    @Local private var speed = 1.0
    @Local private var speedNote: String?

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
            Bubble(shown: shown, order: 0) {
                RoundIcon("backward.fill", help: "Previous song") { nowPlaying.send(.previous) }
            }
            Bubble(shown: shown, order: 1) {
                RoundIcon(nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                          help: nowPlaying.isPlaying ? "Pause" : "Play", size: 44) {
                    nowPlaying.send(.togglePlayPause)
                }
            }
            Bubble(shown: shown, order: 2) {
                RoundIcon("forward.fill", help: "Next song") { nowPlaying.send(.next) }
            }
            }
            // Speed sits on the right so play/pause stays dead center.
            HStack {
            Spacer()
            Bubble(shown: shown, order: 3) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { speedOpen.toggle() }
                    } label: {
                        Text(speedLabel(speed))
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .help("Playback speed")
                    if speedOpen {
                        SpeedSlider(value: $speed) { done in
                            nowPlaying.setSpeed(done)
                            checkSpeed(done)
                        }
                        .frame(width: 170)
                        .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, speedOpen ? 12 : 0)
                .background(Capsule().fill(.white.opacity(0.12)))
            }
            }
        }
        .overlay(alignment: .top) {
            if let speedNote, shown {
                Text(speedNote).font(.caption).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .offset(y: -34)
                    .transition(.opacity)
            }
        }
        .onAppear { speed = nowPlaying.playbackRate }
        .onChange(of: shown) { _, now in if !now { withAnimation { speedOpen = false } } }
    }

    private func speedLabel(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))×" : String(format: "%.1f×", v)
    }

    /// Some players ignore speed changes; say so instead of pretending it worked.
    private func checkSpeed(_ wanted: Double) {
        let app = nowPlaying.track?.playerName ?? "This player"
        if nowPlaying.track?.bundleID == "com.google.Chrome" { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard nowPlaying.isPlaying else { return }
            if abs(nowPlaying.playbackRate - wanted) > 0.05 {
                withAnimation {
                    speedNote = wanted != wanted.rounded() ? "\(app) only takes whole speeds (1× or 2×) from here"
                                                           : "\(app) doesn't allow speed changes"
                }
                speed = nowPlaying.playbackRate
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { speedNote = nil }
            }
        }
    }
}

/// 0.1× to 2×, with soft white dots at 0.5, 1, 1.5 and 2 that the knob snaps to.
struct SpeedSlider: View {
    @Binding var value: Double
    var onCommit: (Double) -> Void
    private let range = 0.1...2.0
    private let marks = [0.5, 1.0, 1.5, 2.0]

    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 16
            let x = { (v: Double) in 8 + CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: 4).padding(.horizontal, 8)
                Capsule().fill(.white.opacity(0.75)).frame(width: max(0, x(value) - 8), height: 4).offset(x: 8)
                ForEach(marks, id: \.self) { m in
                    Circle().fill(.white.opacity(value >= m ? 0.95 : 0.45))
                        .frame(width: 5, height: 5)
                        .position(x: x(m), y: g.size.height / 2)
                }
                Circle().fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .position(x: x(value), y: g.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in value = snap(Double((d.location.x - 8) / w)) }
                .onEnded { d in
                    value = snap(Double((d.location.x - 8) / w))
                    onCommit(value)
                })
        }
        .frame(height: 36)
    }

    private func snap(_ t: Double) -> Double {
        let v = range.lowerBound + min(max(t, 0), 1) * (range.upperBound - range.lowerBound)
        if let m = marks.first(where: { abs($0 - v) < 0.06 }) { return m }
        return (v * 10).rounded() / 10
    }
}

/// Solid ↔ glass background. The slider in settings sets how see-through it is.
struct GlassBackground: View {
    @ObservedObject var settings: AppSettings
    var corner: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            VisualEffectBlur()
            settings.background.opacity(1 - settings.glass * 0.85)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct RoundIcon: View {
    let name: String
    let help: String
    var size: CGFloat = 36
    var active = false
    var tint: Color = .white
    let action: () -> Void
    @Local private var over = false
    init(_ name: String, help: String, size: CGFloat = 36, active: Bool = false, tint: Color = .white,
         action: @escaping () -> Void) {
        self.name = name; self.help = help; self.size = size; self.active = active; self.tint = tint
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(active ? Color.black.opacity(0.8) : .white.opacity(over ? 1 : 0.88))
                .frame(width: size, height: size)
                .background(Circle().fill(active ? AnyShapeStyle(tint.opacity(over ? 1 : 0.9))
                                                 : AnyShapeStyle(.white.opacity(over ? 0.24 : 0.13))))
                .scaleEffect(over ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: over)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over = $0 }
    }
}

/// A see-through layer that moves the window when you click and drag on it.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            // As a normal window, clicking it brings it forward like any other window.
            window?.orderFrontRegardless()
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// A vinyl record with the album art in the middle and a white needle arm, like NetEase's
/// player. It spins while the song plays; the arm swings off the record when paused.
/// Size: `width` wide and `width × Turntable.aspect` tall (room above for the arm).
struct Turntable: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var settings: AppSettings
    static let aspect: CGFloat = 1.3
    /// Seconds per full turn.
    private let secondsPerTurn = 12.0

    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height / Self.aspect)
            let top = w * 0.30            // space above the record for the arm
            ZStack(alignment: .topLeading) {
                record(w)
                    .frame(width: w, height: w)
                    .offset(y: top)
                NeedleArm()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: w * 0.012, y: w * 0.006)
                    .frame(width: w, height: w * Self.aspect)
                    // Pivot sits at (0.5, 0.06) of the arm's frame.
                    .rotationEffect(.degrees(nowPlaying.isPlaying ? 0 : -24), anchor: UnitPoint(x: 0.5, y: 0.06 / Self.aspect))
                    .animation(.spring(response: 0.7, dampingFraction: 0.8), value: nowPlaying.isPlaying)
            }
            .frame(width: w, height: w * Self.aspect)
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1 / Self.aspect, contentMode: .fit)
    }

    private func record(_ w: CGFloat) -> some View {
        ZStack {
            // Soft outer ring the record sits in.
            Circle().fill(Color(white: 0.17))
            Circle().strokeBorder(.white.opacity(0.05), lineWidth: 1)
            TimelineView(.animation(paused: !nowPlaying.isPlaying)) { ctx in
                let angle = (nowPlaying.position(at: ctx.date) / secondsPerTurn).truncatingRemainder(dividingBy: 1) * 360
                ZStack {
                    Circle().fill(Color(white: 0.05))
                    ForEach(0..<9) { i in
                        Circle().strokeBorder(Color(white: 0.13).opacity(i % 2 == 0 ? 0.9 : 0.5), lineWidth: 0.7)
                            .padding(w * (0.035 + Double(i) * 0.016))
                    }
                    Group {
                        if let art = nowPlaying.artwork {
                            Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(colors: [settings.highlight, settings.highlight.opacity(0.45)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                    .frame(width: w * 0.58, height: w * 0.58)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: w * 0.012))
                }
                .padding(w * 0.07)
                .rotationEffect(.degrees(angle))
            }
            // Light that stays still while the record turns under it.
            Circle()
                .fill(AngularGradient(colors: [.clear, .white.opacity(0.07), .clear, .clear,
                                               .white.opacity(0.05), .clear], center: .center))
                .padding(w * 0.07)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.4), radius: w * 0.04, y: w * 0.02)
    }
}

/// The white tonearm: a round pivot at the top, a thin arm bending down and right,
/// and a small head resting on the record.
struct NeedleArm: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * w) }
        var p = Path()
        // Pivot: ring with a hole.
        let pivot = pt(0.5, 0.06)
        p.addEllipse(in: CGRect(x: pivot.x - w * 0.045, y: pivot.y - w * 0.045, width: w * 0.09, height: w * 0.09))
        // Arm (stroked as an outline so it fills cleanly).
        var arm = Path()
        arm.move(to: pivot)
        arm.addLine(to: pt(0.53, 0.24))
        arm.addQuadCurve(to: pt(0.69, 0.43), control: pt(0.55, 0.36))
        arm.addLine(to: pt(0.73, 0.49))
        p.addPath(arm.strokedPath(StrokeStyle(lineWidth: w * 0.022, lineCap: .round, lineJoin: .round)))
        // Head (cartridge), tilted along the arm.
        let head = CGRect(x: -w * 0.03, y: -w * 0.05, width: w * 0.06, height: w * 0.1)
        let t = CGAffineTransform(translationX: pt(0.745, 0.51).x, y: pt(0.745, 0.51).y).rotated(by: -.pi / 5.5)
        p.addPath(Path(roundedRect: head, cornerRadius: w * 0.012).applying(t))
        _ = h
        return p
    }
}

/// Short line between the record and the lyrics. Drag anywhere in its tall, invisible
/// grab zone to give either side more room. Built in AppKit so every pixel of the zone
/// grabs on the first click and the resize cursor always shows.
struct SplitHandle: View {
    @Binding var fraction: Double
    var totalWidth: CGFloat
    @Local private var active = false

    var body: some View {
        ZStack {
            GeometryReader { g in
                Capsule()
                    .fill(.white.opacity(active ? 0.55 : 0.22))
                    .frame(width: active ? 4 : 3, height: min(70, max(28, g.size.height * 0.28)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
            SplitGrabber(onHover: { h in withAnimation(.easeOut(duration: 0.15)) { active = h } },
                         onDrag: { dx in
                             fraction = min(0.6, max(0.14, fraction + Double(dx / max(totalWidth, 1))))
                         })
        }
        .frame(width: 26)
        .help("Drag to resize the record and the lyrics")
    }
}

struct SplitGrabber: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onDrag: (CGFloat) -> Void

    final class GrabView: NSView {
        var onHover: ((Bool) -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        private var lastX: CGFloat?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { if lastX == nil { onHover?(false) } }
        override func mouseDown(with event: NSEvent) { lastX = NSEvent.mouseLocation.x }
        override func mouseDragged(with event: NSEvent) {
            let x = NSEvent.mouseLocation.x
            if let l = lastX { onDrag?(x - l) }
            lastX = x
        }
        override func mouseUp(with event: NSEvent) {
            lastX = nil
            let p = convert(event.locationInWindow, from: nil)
            if !bounds.contains(p) { onHover?(false) }
        }
    }

    func makeNSView(context: Context) -> GrabView {
        let v = GrabView()
        v.onHover = onHover; v.onDrag = onDrag
        return v
    }
    func updateNSView(_ v: GrabView, context: Context) { v.onHover = onHover; v.onDrag = onDrag }
}

/// Timeline of the song: time played on the left, song length on the right, and a bar you can
/// click or drag to jump anywhere. While dragging, the time shows where you'll land.
struct SeekBar: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor
    var tint: Color
    /// Light text and track for the dark island; the dashboard uses the system colors.
    var onDark = true
    @Local private var dragging: Double?   // 0...1 while dragging
    @Local private var over = false

    var body: some View {
        let duration = nowPlaying.track?.duration ?? 0
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let played = min(duration, max(0, nowPlaying.position(at: ctx.date)))
            let fraction = dragging ?? (duration > 0 ? played / duration : 0)
            HStack(spacing: 10) {
                time(dragging.map { $0 * duration } ?? played)
                GeometryReader { g in
                    let w = g.size.width
                    let h: CGFloat = over || dragging != nil ? 6 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(onDark ? Color.white.opacity(0.2) : Color.primary.opacity(0.12))
                            .frame(height: h)
                        Capsule().fill(tint)
                            .frame(width: max(h, w * fraction), height: h)
                        Circle().fill(.white)
                            .frame(width: 13, height: 13)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .offset(x: w * fraction - 6.5)
                            .opacity(over || dragging != nil ? 1 : 0)
                    }
                    .frame(height: g.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { d in dragging = min(1, max(0, d.location.x / max(w, 1))) }
                        .onEnded { d in
                            let f = min(1, max(0, d.location.x / max(w, 1)))
                            nowPlaying.seek(to: f * duration)
                            dragging = nil
                        })
                }
                .frame(height: 16)
                time(duration)
            }
            .animation(.easeOut(duration: 0.15), value: over)
        }
        .opacity(duration > 0 ? 1 : 0.4)
        .allowsHitTesting(duration > 0)
        .onHover { over = $0 }
        .help(duration > 0 ? "Drag to jump anywhere in the song" : "This player doesn't report the song's length")
    }

    private func time(_ t: Double) -> some View {
        let s = Int(t.rounded(.down))
        return Text(String(format: "%d:%02d", s / 60, s % 60))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(onDark ? Color.white.opacity(0.75) : Color.secondary)
            .frame(width: 36)
    }
}

/// Heart and + for the island's top-left corner.
struct IslandSongButtons: View {
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    var song: SavedSong
    var shown: Bool
    @Binding var picking: Bool

    var body: some View {
        let liked = library.isLiked(song.id)
        HStack(spacing: 8) {
            Bubble(shown: shown, order: 0) {
                RoundIcon(liked ? "heart.fill" : "heart",
                          help: liked ? "Remove from Liked Songs" : "Add to Liked Songs",
                          active: liked, tint: Color(hex: "#FF5E8A")) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { library.toggleLike(song.id) }
                }
            }
            Bubble(shown: shown, order: 1) {
                RoundIcon("plus", help: "Add to album", active: picking, tint: settings.highlight) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { picking.toggle() }
                }
            }
        }
    }
}
