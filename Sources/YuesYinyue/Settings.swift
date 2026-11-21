import SwiftUI

/// What to do when a song only has a start time for each line (no per-word timing).
enum LineFill: String, CaseIterable, Identifiable {
    case wholeLine   // light up the whole line when it starts (what most lyric apps do)
    case sweep       // estimate: sweep the color evenly across the line
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wholeLine: return "Light up the whole line"
        case .sweep: return "Sweep across the line (estimated)"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How the theme colors are used on the dashboard background.
enum ThemeStyle: String, CaseIterable, Identifiable {
    case albumArt   // blurred album art of what's playing (falls back to the theme colors)
    case aurora     // soft blobs of the two colors
    case gradient   // diagonal fade from primary to secondary
    case solid      // a light wash of the primary color
    case minimal    // plain window color, theme color only on accents
    var id: String { rawValue }
    var label: String {
        switch self {
        case .albumArt: return "Album art"
        case .aurora: return "Aurora"
        case .gradient: return "Gradient"
        case .solid: return "Solid"
        case .minimal: return "Minimal"
        }
    }
}

/// Ready-made themes. Picking one sets the style and both colors; any of them can be changed after.
struct ThemePreset: Identifiable {
    var name: String
    var style: ThemeStyle
    var primary: String
    var secondary: String?
    var id: String { name }

    static let all: [ThemePreset] = [
        .init(name: "Album Art", style: .albumArt, primary: "#7FD4FF", secondary: nil),
        .init(name: "Ocean", style: .aurora, primary: "#2E7BFF", secondary: "#1ED6C1"),
        .init(name: "Sakura", style: .aurora, primary: "#FF7EB3", secondary: "#FFC6A8"),
        .init(name: "Matcha", style: .gradient, primary: "#7DBB6A", secondary: "#E3D9A6"),
        .init(name: "Sunset", style: .gradient, primary: "#FF7A45", secondary: "#B14BFF"),
        .init(name: "Lavender", style: .solid, primary: "#9C8CFF", secondary: nil),
        .init(name: "Midnight", style: .aurora, primary: "#3B3F9E", secondary: "#0E1630"),
        .init(name: "Mono", style: .minimal, primary: "#8E8E93", secondary: nil),
    ]
}

/// All user settings, saved automatically in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("highlightHex") var highlightHex = "#7FD4FF"
    @AppStorage("backgroundHex") var backgroundHex = "#16181D"
    /// 0 = solid color, 1 = full glass
    @AppStorage("glass") var glass = 0.6
    @AppStorage("toneStyle") var toneStyleRaw = ToneStyle.marks.rawValue
    @AppStorage("lineFill") var lineFillRaw = LineFill.wholeLine.rawValue
    @AppStorage("fontSize") var fontSize = 26.0
    @AppStorage("showPinyin") var showPinyin = true
    /// Show the island on every desktop (Space), or only the one it's on.
    @AppStorage("allSpaces") var allSpaces = true
    /// true = the island stays above every window; false = it acts like a normal window.
    @AppStorage("alwaysOnTop") var alwaysOnTop = true
    /// A spinning record with the album art, just for looks.
    @AppStorage("showDisc") var showDisc = false
    /// Share of the island's width the record takes (the rest is lyrics).
    @AppStorage("discSplit") var discSplit = 0.32
    /// Seconds the highlight runs ahead of the reported playback time, for every song.
    @AppStorage("leadTime") var leadTime = 0.3

    // Dashboard look
    @AppStorage("appearance") var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("themeStyle") var themeStyleRaw = ThemeStyle.albumArt.rawValue
    @AppStorage("themePrimary") var themePrimaryHex = "#7FD4FF"
    @AppStorage("themeSecondary") var themeSecondaryHex = "#B07FFF"
    /// false = the second color is worked out from the first.
    @AppStorage("themeUseSecondary") var themeUseSecondary = false

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }
    var themeStyle: ThemeStyle {
        get { ThemeStyle(rawValue: themeStyleRaw) ?? .albumArt }
        set { themeStyleRaw = newValue.rawValue }
    }
    var primary: Color {
        get { Color(hex: themePrimaryHex) }
        set { themePrimaryHex = newValue.hex; objectWillChange.send() }
    }
    /// The chosen second color, or one made from the primary: the hue turned 35° and a bit deeper.
    var secondary: Color {
        get {
            if themeUseSecondary { return Color(hex: themeSecondaryHex) }
            let c = NSColor(primary).usingColorSpace(.sRGB) ?? .systemBlue
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
            return Color(hue: (h + 35 / 360).truncatingRemainder(dividingBy: 1),
                         saturation: min(1, sat * 1.1), brightness: b * 0.8)
        }
        set { themeSecondaryHex = newValue.hex; objectWillChange.send() }
    }

    func apply(_ p: ThemePreset) {
        themeStyle = p.style
        themePrimaryHex = p.primary
        if let s = p.secondary { themeSecondaryHex = s; themeUseSecondary = true } else { themeUseSecondary = false }
        objectWillChange.send()
    }

    var highlight: Color {
        get { Color(hex: highlightHex) }
        set { highlightHex = newValue.hex; objectWillChange.send() }
    }
    var background: Color {
        get { Color(hex: backgroundHex) }
        set { backgroundHex = newValue.hex; objectWillChange.send() }
    }
    var toneStyle: ToneStyle {
        get { ToneStyle(rawValue: toneStyleRaw) ?? .marks }
        set { toneStyleRaw = newValue.rawValue }
    }
    var lineFill: LineFill {
        get { LineFill(rawValue: lineFillRaw) ?? .wholeLine }
        set { lineFillRaw = newValue.rawValue }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    /// Blend from this color toward `other` by `t` (0...1).
    func mix(_ other: Color, _ t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let k = max(0, min(1, t))
        return Color(.sRGB,
                     red: a.redComponent + (b.redComponent - a.redComponent) * k,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k)
    }
}
