// Settings shared by the island and the dashboard. Saved on this computer; both windows see
// changes right away (the browser's "storage" event fires in the other window).
import type { ToneStyle } from "../core/reading.ts";

export interface Theme { id: string; name: string; primary: string; secondary: string; highlight: string; island: string; followsArt?: boolean }

// The same curated themes as the Mac app.
export const THEMES: Theme[] = [
  { id: "album", name: "Album", primary: "#7FD4FF", secondary: "#9B8CFF", highlight: "#7FD4FF", island: "#14161C", followsArt: true },
  { id: "midnight", name: "Midnight", primary: "#7C8CFF", secondary: "#3A2F8F", highlight: "#A9B6FF", island: "#11131C" },
  { id: "sakura", name: "Sakura", primary: "#FF8FB1", secondary: "#FFB59A", highlight: "#FFA3C2", island: "#1C1317" },
  { id: "ocean", name: "Ocean", primary: "#2FB4FF", secondary: "#1ED6C1", highlight: "#7FE3FF", island: "#0D1820" },
  { id: "ember", name: "Ember", primary: "#FF7A45", secondary: "#E83E6C", highlight: "#FFB48A", island: "#1B120F" },
  { id: "matcha", name: "Matcha", primary: "#8FD07C", secondary: "#D9CF8F", highlight: "#B9F2A3", island: "#111811" },
  { id: "lavender", name: "Lavender", primary: "#B79CFF", secondary: "#7AA2FF", highlight: "#CDB8FF", island: "#15121D" },
  { id: "sunset", name: "Sunset", primary: "#FF9A5A", secondary: "#B45CFF", highlight: "#FFC08A", island: "#1B1219" },
  { id: "forest", name: "Forest", primary: "#4FBF8B", secondary: "#2E6B5A", highlight: "#8FE3B9", island: "#0F1714" },
  { id: "coral", name: "Coral", primary: "#FF7F7F", secondary: "#FFB36B", highlight: "#FFA8A0", island: "#1C1312" },
  { id: "lagoon", name: "Lagoon", primary: "#3FD0D4", secondary: "#3B6FE0", highlight: "#8DEFF0", island: "#0C1619" },
  { id: "plum", name: "Plum", primary: "#D46FB4", secondary: "#6B3FA0", highlight: "#F0A6D6", island: "#1A1018" },
  { id: "gold", name: "Gold", primary: "#E6B94F", secondary: "#9C6B2E", highlight: "#F7D98A", island: "#18140D" },
  { id: "arctic", name: "Arctic", primary: "#9FD8FF", secondary: "#E6F2FF", highlight: "#CFEFFF", island: "#101820" },
  { id: "cherry", name: "Cherry", primary: "#E5484D", secondary: "#8C1D2F", highlight: "#FF8A8F", island: "#1A0F11" },
  { id: "mono", name: "Mono", primary: "#C9C9D1", secondary: "#6E6E7A", highlight: "#F5D76E", island: "#141416" },
];

const get = (k: string, d: string) => localStorage.getItem(k) ?? d;
const set = (k: string, v: string) => localStorage.setItem(k, v);

export const settings = {
  get theme() { return THEMES.find((t) => t.id === get("theme", "album")) ?? THEMES[0]; },
  set themeID(v: string) { set("theme", v); },
  get appearance() { return get("appearance", "system") as "system" | "light" | "dark"; }, set appearance(v) { set("appearance", v); },
  get tone() { return get("tone", "symbol") as ToneStyle; }, set tone(v: ToneStyle) { set("tone", v); },
  get reading() { return get("reading", "1") === "1"; }, set reading(v: boolean) { set("reading", v ? "1" : "0"); },
  get fontSize() { return Number(get("fontSize", "26")); }, set fontSize(v: number) { set("fontSize", String(v)); },
  get glass() { return Number(get("glass", "0.6")); }, set glass(v: number) { set("glass", String(v)); },
  get lead() { return Number(get("lead", "0.3")); }, set lead(v: number) { set("lead", String(v)); },
  get onTop() { return get("onTop", "1") === "1"; }, set onTop(v: boolean) { set("onTop", v ? "1" : "0"); },
  get lineFill() { return get("lineFill", "wholeLine") as "wholeLine" | "sweep"; }, set lineFill(v) { set("lineFill", v); },
  get showDisc() { return get("showDisc", "0") === "1"; }, set showDisc(v: boolean) { set("showDisc", v ? "1" : "0"); },
  get artColor() { return get("artColor", ""); }, set artColor(v: string) { set("artColor", v); },
};

// ---------- colors ----------
const hex = (h: string) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const toHex = (rgb: number[]) => "#" + rgb.map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join("");

function hsv(h: string): [number, number, number] {
  const [r, g, b] = hex(h).map((v) => v / 255), mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  let hue = 0;
  if (d) hue = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [((hue * 60) + 360) % 360, mx ? d / mx : 0, mx];
}
function fromHsv(h: number, s: number, v: number): string {
  const c = v * s, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = v - c;
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return toHex([r, g, b].map((n) => (n + m) * 255));
}
/** Same hue, brightness set so it reads well on dark glass (like the Mac app's `vivid`). */
export function vivid(color: string, brightness: number, saturation = 0.7, hueShift = 0): string {
  const [h, s] = hsv(color);
  const sat = s < 0.12 ? 0.08 : Math.max(saturation * 0.8, Math.min(saturation, s * 1.3));
  return fromHsv((h + hueShift) % 360, sat, brightness);
}
export const mix = (a: string, b: string, t: number) => { const x = hex(a), y = hex(b); return toHex(x.map((v, i) => v + (y[i] - v) * t)); };

/** The colors in use right now: the theme's, or the album art's for the Album theme. */
export function colors() {
  const t = settings.theme, art = settings.artColor;
  if (t.followsArt && art) return { primary: vivid(art, 0.95), secondary: vivid(art, 0.6, 0.7, 30), highlight: vivid(art, 1, 0.55), island: t.island };
  return { primary: t.primary, secondary: t.secondary, highlight: t.highlight, island: t.island };
}

/** Puts the current colors and light/dark mode on the page as CSS variables. */
export function applyTheme() {
  const c = colors(), root = document.documentElement;
  root.style.setProperty("--primary", c.primary);
  root.style.setProperty("--secondary", c.secondary);
  root.style.setProperty("--hl", c.highlight);
  root.style.setProperty("--island", c.island);
  root.style.setProperty("--glass", String(1 - settings.glass * 0.85));
  root.style.setProperty("--font", `${settings.fontSize}px`);
  const dark = settings.appearance === "dark" || (settings.appearance === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  root.classList.toggle("dark", dark);
  root.classList.toggle("light", !dark);
}

/** Average color of an image (for the Album theme). */
export function averageColor(dataUrl: string): Promise<string> {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement("canvas");
      c.width = c.height = 1;
      const ctx = c.getContext("2d")!;
      ctx.drawImage(img, 0, 0, 1, 1);
      const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data;
      resolve(toHex([r, g, b]));
    };
    img.onerror = () => resolve("");
    img.src = dataUrl;
  });
}

export function onSettingsChange(fn: () => void) {
  addEventListener("storage", fn);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", fn);
}
