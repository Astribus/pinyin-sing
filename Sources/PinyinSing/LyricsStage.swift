import AppKit
import SwiftUI

/// The scrolling karaoke lyrics. Used by the floating window and inside the app.
struct LyricsStage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var nowPlaying: NowPlayingMonitor
    /// Fixed number of line pairs, or nil to fit as many as the height allows.
    var fixedLines: Int? = nil

    /// nil = following the song. A number = the line the user scrolled to (can be fractional).
    @Local private var browse: Double?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let song = model.song, song.timing != .none {
                    ZStack(alignment: .top) {
                        ScrollCatcher { dy in scrolled(by: dy, song: song) }
                        TimelineView(.animation(paused: !nowPlaying.isPlaying && browse == nil)) { ctx in
                            stage(song: song, t: model.position(at: ctx.date), height: geo.size.height)
                        }
                        if browse != nil {
                            Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { browse = nil } } label: {
                                Label("Back to now", systemImage: "arrow.uturn.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(settings.highlight.opacity(0.55)))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                } else if let song = model.song {
                    untimed(song)
                } else {
                    message
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: model.song?.id) { browse = nil }
    }

    private var rowHeight: Double {
        settings.fontSize * (settings.showPinyin ? 2.05 : 1.35) + 16
    }

    /// Scroll wheel / trackpad moves through the lyrics. Scrolling back onto the line being
    /// sung goes back to following the song.
    private func scrolled(by dy: Double, song: SavedSong) {
        let cur = Double(max(0, Karaoke.currentIndex(song.lines, t: model.position(at: Date()))))
        let start = browse ?? cur
        let next = min(Double(song.lines.count - 1), max(0, start - dy / rowHeight))
        if browse != nil, abs(next - cur) < 0.3 {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { browse = nil }
        } else {
            browse = next
        }
    }

    @ViewBuilder
    private func stage(song: SavedSong, t: Double, height: Double) -> some View {
        let lines = song.lines
        let cur = Karaoke.currentIndex(lines, t: t)
        // Start scrolling 0.35 s before the next line, so it's already centered when it's sung.
        let scrollCur = Karaoke.currentIndex(lines, t: t + 0.35)
        let count = fixedLines ?? max(1, min(9, Int(height / rowHeight)))
        let focus = browse ?? Double(max(scrollCur, 0))
        // The line being sung always sits in the middle.
        let anchor = (height - rowHeight) / 2
        let half = count / 2 + 2
        let lo = max(0, Int(focus.rounded(.down)) - half)
        let hi = min(lines.count - 1, Int(focus.rounded(.up)) + half)

        ZStack(alignment: .top) {
            if lo <= hi {
                ForEach(lo...hi, id: \.self) { i in
                    let line = lines[i]
                    let tokens = PinyinEngine.shared.tokens(for: line, style: settings.toneStyle)
                    let next = i + 1 < lines.count ? lines[i + 1].start : song.duration
                    let p: [Double] = i < cur - 1 ? Array(repeating: 1, count: tokens.count)
                        : i > cur + 1 ? Array(repeating: 0, count: tokens.count)
                        : Karaoke.progress(line: line, tokens: tokens, next: next, t: t,
                                           timing: song.timing, fill: settings.lineFill)
                    LinePair(tokens: tokens, progress: p, settings: settings,
                             distance: browse == nil ? abs(i - max(scrollCur, 0)) : 0,
                             // Lines hidden in the faded edges don't take clicks.
                             onTap: abs(Double(i) - focus) <= Double(count / 2) ? { jump(to: line) } : nil)
                        .frame(height: rowHeight)
                        .offset(y: anchor + (Double(i) - focus) * rowHeight)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Springy scroll, like Apple Music lyrics (only while following the song).
        .animation(browse == nil ? .spring(response: 0.5, dampingFraction: 0.84) : nil, value: scrollCur)
        // Fade out at the top and bottom edges.
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.16),
            .init(color: .black, location: 0.84),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }

    private func jump(to line: LyricLine) {
        model.seek(toLyricTime: line.start)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { browse = nil }
    }

    private func untimed(_ song: SavedSong) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("No timing for these lyrics, so they won't highlight.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                ForEach(song.lines) { line in
                    LinePair(tokens: PinyinEngine.shared.tokens(for: line, style: settings.toneStyle),
                             progress: [], settings: settings, distance: 0)
                }
            }
            .padding(22)
        }
    }

    private var message: some View {
        VStack(spacing: 8) {
            switch model.status {
            case .idle:
                Text("Play a song").font(.system(size: 18, weight: .semibold))
                Text("汽水音乐 · NetEase · Spotify · YouTube").font(.caption).opacity(0.6)
            case .searching:
                ProgressView().controlSize(.small).tint(.white)
                Text("Finding lyrics…").font(.system(size: 15, weight: .medium))
            case .notFound:
                Text("No lyrics found").font(.system(size: 17, weight: .semibold))
                Text("Copy the song's 汽水音乐 link, paste lyrics, or try Listen").font(.caption).opacity(0.7)
            case .found:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One Chinese line with its pinyin right underneath.
struct LinePair: View {
    let tokens: [Token]
    let progress: [Double]
    @ObservedObject var settings: AppSettings
    let distance: Int
    /// Click handler. Only the words themselves are clickable, so the empty space
    /// around them still drags the island.
    var onTap: (() -> Void)? = nil
    @Local private var hovered = false

    var body: some View {
        let lit = hovered && onTap != nil
        VStack(spacing: 3) {
            colored(tokens.indices.map { (tokens[$0].text, p($0)) })
                .font(.system(size: settings.fontSize, weight: .semibold))
            if settings.showPinyin, tokens.contains(where: { $0.pinyin != nil }) {
                colored(pinyinParts())
                    .font(.system(size: settings.fontSize * 0.56, weight: .medium, design: .rounded))
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 12).padding(.vertical, 4)
        // Pointing at a line lights it up so it's clear it can be clicked.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(lit ? 0.10 : 0)))
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovered = h }
            if onTap != nil { if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        .onTapGesture { onTap?() }
        // Click = jump the song; click and move = drag the island like anywhere else.
        .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in
            if let e = NSApp.currentEvent, e.type == .leftMouseDragged,
               let w = e.window as? OverlayPanel {
                w.performDrag(with: e)
            }
        })
        .allowsHitTesting(onTap != nil)
        .help(onTap != nil ? "Click to play from this line" : "")
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)  // readable on any background, no glow
        .opacity(distance == 0 || lit ? 1 : max(0.35, 1 - 0.22 * Double(distance)))
        .blur(radius: lit ? 0 : Double(min(distance, 3)) * 0.9)          // AMLL-style depth
        .scaleEffect(distance == 0 || lit ? 1 : 0.96)
        .animation(.easeOut(duration: 0.35), value: distance)
    }

    private func p(_ i: Int) -> Double { i < progress.count ? progress[i] : 0 }

    private func pinyinParts() -> [(String, Double)] {
        var parts: [(String, Double)] = []
        for i in tokens.indices {
            guard let py = tokens[i].pinyin else { continue }
            if !parts.isEmpty { parts.append((" ", p(i))) }
            parts.append((py, p(i)))
        }
        return parts
    }

    private func colored(_ parts: [(String, Double)]) -> Text {
        parts.reduce(Text("")) { acc, part in
            acc + Text(part.0).foregroundColor(Color.white.mix(settings.highlight, part.1))
        }
    }
}

/// Hears scroll-wheel and trackpad scrolling over the lyrics without blocking clicks or
/// window dragging underneath (it never takes part in hit testing).
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (Double) -> Void

    final class CatchView: NSView {
        var onScroll: ((Double) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12
                self.onScroll?(Double(dy))
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> CatchView {
        let v = CatchView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ v: CatchView, context: Context) { v.onScroll = onScroll }
}
