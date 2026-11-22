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
    var short: String {
        switch self {
        case .wholeLine: return "Whole line"
        case .sweep: return "Sweep"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A curated look: dashboard colors, the color sung words turn, and the island's color.
/// Users pick from these instead of mixing their own, so it always looks good.
struct Theme: Identifiable, Equatable {
    var id: String
    var name: String
    var primary: String
    var secondary: String
    var highlight: String     // sung words
    var island: String        // island background
    /// Takes its colors from the album art of what's playing.
    var followsArt = false

    static let all: [Theme] = [
        Theme(id: "album", name: "Album", primary: "#7FD4FF", secondary: "#9B8CFF", highlight: "#7FD4FF",
              island: "#14161C", followsArt: true),
        Theme(id: "midnight", name: "Midnight", primary: "#7C8CFF", secondary: "#3A2F8F", highlight: "#A9B6FF", island: "#11131C"),
        Theme(id: "sakura", name: "Sakura", primary: "#FF8FB1", secondary: "#FFB59A", highlight: "#FFA3C2", island: "#1C1317"),
        Theme(id: "ocean", name: "Ocean", primary: "#2FB4FF", secondary: "#1ED6C1", highlight: "#7FE3FF", island: "#0D1820"),
        Theme(id: "ember", name: "Ember", primary: "#FF7A45", secondary: "#E83E6C", highlight: "#FFB48A", island: "#1B120F"),
        Theme(id: "matcha", name: "Matcha", primary: "#8FD07C", secondary: "#D9CF8F", highlight: "#B9F2A3", island: "#111811"),
        Theme(id: "lavender", name: "Lavender", primary: "#B79CFF", secondary: "#7AA2FF", highlight: "#CDB8FF", island: "#15121D"),
        Theme(id: "sunset", name: "Sunset", primary: "#FF9A5A", secondary: "#B45CFF", highlight: "#FFC08A", island: "#1B1219"),
        Theme(id: "forest", name: "Forest", primary: "#4FBF8B", secondary: "#2E6B5A", highlight: "#8FE3B9", island: "#0F1714"),
        Theme(id: "coral", name: "Coral", primary: "#FF7F7F", secondary: "#FFB36B", highlight: "#FFA8A0", island: "#1C1312"),
        Theme(id: "lagoon", name: "Lagoon", primary: "#3FD0D4", secondary: "#3B6FE0", highlight: "#8DEFF0", island: "#0C1619"),
        Theme(id: "plum", name: "Plum", primary: "#D46FB4", secondary: "#6B3FA0", highlight: "#F0A6D6", island: "#1A1018"),
        Theme(id: "gold", name: "Gold", primary: "#E6B94F", secondary: "#9C6B2E", highlight: "#F7D98A", island: "#18140D"),
        Theme(id: "arctic", name: "Arctic", primary: "#9FD8FF", secondary: "#E6F2FF", highlight: "#CFEFFF", island: "#101820"),
        Theme(id: "cherry", name: "Cherry", primary: "#E5484D", secondary: "#8C1D2F", highlight: "#FF8A8F", island: "#1A0F11"),
        Theme(id: "mono", name: "Mono", primary: "#C9C9D1", secondary: "#6E6E7A", highlight: "#F5D76E", island: "#141416"),
    ]
    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

/// All user settings, saved automatically in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
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
    /// Records line-timed songs once and times every character to the singing.
    @AppStorage("syncWords") var syncWords = true
    /// Show an English translation under each line (off until the user turns it on).
    @AppStorage("showTranslation") var showTranslation = false

    // Dashboard look
    @AppStorage("appearance") var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("themeID") var themeID = "album"
    /// Average color of the current album art (used by the Album theme).
    @Published var artColor: Color?

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }
    var theme: Theme { Theme.named(themeID) }

    /// Dashboard accent. The Album theme uses the album art's color, lifted so it stays readable.
    var primary: Color {
        if theme.followsArt, let art = artColor { return art.vivid(brightness: 0.95) }
        return Color(hex: theme.primary)
    }
    var secondary: Color {
        if theme.followsArt, let art = artColor { return art.vivid(brightness: 0.6, hueShift: 30) }
        return Color(hex: theme.secondary)
    }
    /// The color sung words turn (from the theme).
    var highlight: Color {
        if theme.followsArt, let art = artColor { return art.vivid(brightness: 1.0, saturation: 0.55) }
        return Color(hex: theme.highlight)
    }
    /// The island's background color (from the theme).
    var background: Color { Color(hex: theme.island) }
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

    /// Same hue, with brightness/saturation set so it reads well on dark glass.
    func vivid(brightness: CGFloat, saturation: CGFloat = 0.7, hueShift: CGFloat = 0) -> Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Grey art has no real hue; keep it calm instead of inventing a color.
        let sat = s < 0.12 ? 0.08 : max(saturation * 0.8, min(saturation, s * 1.3))
        return Color(hue: (h + hueShift / 360).truncatingRemainder(dividingBy: 1), saturation: sat, brightness: brightness)
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
