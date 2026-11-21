import CoreImage
import SwiftUI

/// The background behind the whole dashboard: the album art, blurred once per song, with soft
/// shapes in the theme's two colors drifting slowly over it. Built from Core Animation layers so
/// the motion runs on the GPU without redrawing anything (smooth, and cheap for the glass cards
/// on top). Holds still when Reduce Motion is on.
struct LivingBackdrop: NSViewRepresentable {
    var image: NSImage?
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> BackdropView { BackdropView() }

    func updateNSView(_ v: BackdropView, context: Context) {
        v.update(image: image, primary: NSColor(settings.primary), secondary: NSColor(settings.secondary),
                 dark: scheme == .dark, still: reduceMotion)
    }

    final class BackdropView: NSView {
        private let base = CALayer()
        private let art = CALayer()
        private let blobs = (0..<3).map { _ in CAGradientLayer() }
        private let shade = CAGradientLayer()
        private weak var lastImage: NSImage?
        private var still = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            art.contentsGravity = .resizeAspectFill
            art.masksToBounds = true
            [base, art].forEach { layer!.addSublayer($0) }
            for b in blobs {
                b.type = .radial
                b.startPoint = CGPoint(x: 0.5, y: 0.5)
                b.endPoint = CGPoint(x: 1, y: 1)
                layer!.addSublayer(b)
            }
            layer!.addSublayer(shade)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let r = bounds
            base.frame = r; art.frame = r; shade.frame = r
            let w = r.width, h = r.height
            let sizes: [CGFloat] = [1.1, 1.0, 0.9]
            let centers = [CGPoint(x: w * 0.15, y: h * 0.9), CGPoint(x: w * 0.9, y: h * 0.5), CGPoint(x: w * 0.4, y: -h * 0.05)]
            for (i, b) in blobs.enumerated() {
                let d = max(w, h) * sizes[i]
                b.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                b.position = centers[i]
            }
            CATransaction.commit()
            // Restart the drift from the new positions after a resize.
            blobs.forEach { $0.removeAnimation(forKey: "drift") }
            startDrift()
        }

        func update(image: NSImage?, primary: NSColor, secondary: NSColor, dark: Bool, still: Bool) {
            self.still = still
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.8)
            base.backgroundColor = NSColor.windowBackgroundColor.cgColor
            if image !== lastImage {
                lastImage = image
                art.contents = image.flatMap(Self.blurred)
            }
            art.opacity = image == nil ? 0 : (dark ? 0.55 : 0.4)
            let mix = primary.blended(withFraction: 0.5, of: secondary) ?? primary
            let colors = [primary, secondary, mix]
            let strengths: [CGFloat] = dark ? [0.42, 0.36, 0.3] : [0.3, 0.26, 0.22]
            for (i, b) in blobs.enumerated() {
                b.colors = [colors[i].withAlphaComponent(strengths[i]).cgColor, colors[i].withAlphaComponent(0).cgColor]
            }
            shade.colors = dark ? [NSColor.black.withAlphaComponent(0.5).cgColor, NSColor.black.withAlphaComponent(0.15).cgColor]
                                : [NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0.1).cgColor]
            CATransaction.commit()
            if still { blobs.forEach { $0.removeAllAnimations() } } else { startDrift() }
        }

        /// Slow back-and-forth drift on the GPU (Core Animation runs it, no redraws).
        private func startDrift() {
            guard !still, bounds.width > 0 else { return }
            let w = bounds.width, h = bounds.height
            let moves = [CGSize(width: w * 0.08, height: h * 0.06), CGSize(width: -w * 0.06, height: h * 0.09),
                         CGSize(width: w * 0.07, height: -h * 0.05)]
            let periods: [Double] = [18, 22, 26]
            for (i, b) in blobs.enumerated() where b.animation(forKey: "drift") == nil {
                let a = CABasicAnimation(keyPath: "position")
                a.fromValue = NSValue(point: b.position)
                a.toValue = NSValue(point: CGPoint(x: b.position.x + moves[i].width, y: b.position.y + moves[i].height))
                a.duration = periods[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                b.add(a, forKey: "drift")
            }
        }

        /// Blurs a small copy of the art once, instead of blurring a full-size image every frame.
        private static func blurred(_ image: NSImage) -> CGImage? {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let small = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 160 / CGFloat(cg.width),
                                                                               y: 160 / CGFloat(cg.height)))
            let out = small.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
                .cropped(to: small.extent)
            return CIContext().createCGImage(out, from: small.extent)
        }
    }
}

/// Our own sidebar: frosted glass, rounded rows, and a selection pill in the theme color that
/// slides to whatever you click.
struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LyricsLibrary
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: LibraryUI
    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic-light buttons.
            Color.clear.frame(height: 40)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                Text("音乐")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [settings.primary, settings.secondary],
                                                    startPoint: .leading, endPoint: .trailing))
            }
            .padding(.horizontal, 18).padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    row(.home, "Home", "house.fill")
                    row(.nowPlaying, "Now Playing", "play.circle.fill")

                    header("Library")
                    row(.songs(app: nil), "All Songs", "music.note.list", count: library.songs.count)
                    ForEach(apps, id: \.self) { app in
                        row(.songs(app: app), Track.name(forBundle: app), AppIcon.symbol(app),
                            count: library.songs.filter { $0.app == app }.count)
                    }

                    header("Albums")
                    ForEach(library.albums) { a in
                        row(.album(a.id), a.name, a.id == LyricsLibrary.likedID ? "heart.fill" : "square.stack.fill",
                            count: a.songIDs.count)
                    }
                    Button { ui.namingAlbum = .init(songID: nil) } label: {
                        Label("New Album", systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    header("App")
                    row(.customize, "Customization", "paintpalette.fill")
                    row(.settings, "Settings", "gearshape.fill")
                }
                .padding(.horizontal, 10)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    FooterIcon(symbol: "arrow.down.to.line.compact", on: false, tint: settings.primary,
                               help: "Move the island to bottom-center") { model.resetIsland() }
                    FooterIcon(symbol: settings.allSpaces ? "square.on.square" : "square", on: settings.allSpaces,
                               tint: settings.primary,
                               help: settings.allSpaces ? "Island on every desktop (click for this desktop only)"
                                                        : "Island on this desktop only (click for every desktop)") {
                        settings.allSpaces.toggle()
                    }
                    FooterIcon(symbol: settings.alwaysOnTop ? "pin.fill" : "pin.slash", on: settings.alwaysOnTop,
                               tint: settings.primary,
                               help: settings.alwaysOnTop ? "Island always on top (click to make it a normal window)"
                                                          : "Island acts like a normal window (click to keep it on top)") {
                        settings.alwaysOnTop.toggle()
                    }
                }
                IslandSwitch(model: model, settings: settings)
            }
            .padding(10)
        }
        .frame(width: 240)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(1.2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
    }

    private func row(_ page: LibraryUI.Page, _ title: String, _ symbol: String, count: Int? = nil) -> some View {
        let selected = (ui.page ?? .home) == page && ui.openSong == nil
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                ui.openSong = nil
                ui.page = page
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : settings.primary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [settings.primary.opacity(0.95), settings.secondary.opacity(0.85)],
                                             startPoint: .leading, endPoint: .trailing))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
    }

    /// Apps that songs were played from, most songs first (fixed order so rows never jump).
    private var apps: [String] {
        let counts = Dictionary(grouping: library.songs.compactMap(\.app), by: { $0 }).mapValues(\.count)
        return counts.keys.sorted {
            counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : Track.name(forBundle: $0) < Track.name(forBundle: $1)
        }
    }
}

private struct SidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A rounded panel used for cards across the dashboard. A lightly see-through fill instead of a
/// live blur: the background behind it is already soft, and dozens of live blurs made scrolling
/// stutter.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(scheme == .dark ? Color(white: 0.12).opacity(0.62) : Color.white.opacity(0.62)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.14 : 0.5), .white.opacity(0.03)],
                                                       startPoint: .top, endPoint: .bottom)))
            .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
    }
}

extension View {
    func glassCard(_ radius: CGFloat = 22) -> some View { modifier(GlassCard(radius: radius)) }
}

/// Square icon button for the sidebar footer. Filled with the theme color when it's on.
struct FooterIcon: View {
    var symbol: String
    var on: Bool
    var tint: Color
    var help: String
    var action: () -> Void
    @Local private var over = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(over ? 0.12 : 0.06))))
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over = $0 }
    }
}
