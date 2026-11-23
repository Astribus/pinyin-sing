// The lyrics island for Windows: what's playing → saved or found lyrics → karaoke with readings.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { currentIndex, progress, type Token } from "./core/karaoke.ts";
import { lineTokens, type ToneStyle } from "./core/reading.ts";
import { find, match, qishui, type SavedSong, type Track } from "./core/search.ts";
import { songKey } from "./core/titles.ts";

interface NowPlaying { title: string; artist: string; duration: number; position: number; updatedMs: number; playing: boolean; app: string }

// ---------- icons (drawn, not emoji) ----------
const svg = (d: string, fill = true) =>
  `<svg width="16" height="16" viewBox="0 0 24 24" ${fill ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"'}>${d}</svg>`;
const ICONS: Record<string, string> = {
  prev: svg('<path d="M6 5h2v14H6zM20 5v14L9 12z"/>'),
  next: svg('<path d="M16 5h2v14h-2zM4 5v14l11-7z"/>'),
  play: svg('<path d="M7 4v16l13-8z"/>'),
  pause: svg('<path d="M6 4h4v16H6zM14 4h4v16h-4z"/>'),
  pin: svg('<path d="M16 3l5 5-3 1-4 4 1 5-2 2-4-4-5 5-1-1 5-5-4-4 2-2 5 1 4-4z"/>'),
  gear: svg('<circle cx="12" cy="12" r="3.2"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>', false),
  close: svg('<path d="M6 6l12 12M18 6L6 18"/>', false),
};

// ---------- settings (kept on this computer) ----------
const COLORS = ["#7FD4FF", "#A9B6FF", "#FFA3C2", "#7FE3FF", "#FFB48A", "#B9F2A3", "#F5D76E"];
const store = {
  get hl() { return localStorage.getItem("hl") ?? COLORS[0]; }, set hl(v) { localStorage.setItem("hl", v); },
  get tone() { return (localStorage.getItem("tone") ?? "symbol") as ToneStyle; }, set tone(v) { localStorage.setItem("tone", v); },
  get reading() { return localStorage.getItem("reading") !== "0"; }, set reading(v) { localStorage.setItem("reading", v ? "1" : "0"); },
  get lead() { return Number(localStorage.getItem("lead") ?? 0.3); }, set lead(v) { localStorage.setItem("lead", String(v)); },
  get onTop() { return localStorage.getItem("onTop") !== "0"; }, set onTop(v) { localStorage.setItem("onTop", v ? "1" : "0"); },
};

// ---------- state ----------
let np: NowPlaying | null = null;
let song: SavedSong | null = null;
let status: "idle" | "searching" | "found" | "notFound" = "idle";
let songs: SavedSong[] = [];
let lastKey = "";
let browse: number | null = null;   // line index the user scrolled to, or null when following
let builtFor = "";                  // song id the line elements were built for
let tokens: Token[][] = [];
let lastCur = -2;

const $ = (id: string) => document.getElementById(id)!;
const fetchText = (url: string, referer?: string) => invoke<string>("fetch_text", { url, referer: referer ?? null });

function songTime(now = Date.now()): number {
  if (!np) return 0;
  const p = np.position + (np.playing ? (now - np.updatedMs) / 1000 : 0);
  return Math.min(np.duration || Infinity, Math.max(0, p));
}
const lyricTime = () => songTime() + (song?.offset ?? 0) + store.lead;

async function save(s: SavedSong) {
  songs = songs.filter((x) => x.id !== s.id).concat(s);
  await invoke("save_song", { id: s.id, json: JSON.stringify(s) });
}

// ---------- what's playing ----------
async function trackChanged() {
  if (!np) { status = "idle"; song = null; lastKey = ""; render(); return; }
  const key = songKey(np.title, np.artist);
  if (key === lastKey) return;
  lastKey = key;
  browse = null;
  const track: Track = { title: np.title, artist: np.artist, duration: np.duration };
  const hit = match(songs, track);
  if (hit) {
    song = hit.song;
    if (hit.fuzzy) { song.aliases = [...(song.aliases ?? []), key]; await save(song); }
    status = "found"; render(); return;
  }
  song = null; status = "searching"; render();
  const found = await find(fetchText, track);
  if (lastKey !== key) return;
  if (found) { song = found; status = "found"; await save(found); } else status = "notFound";
  render();
}

// ---------- drawing ----------
const rowHeight = () => {
  const f = 26;
  return f * (store.reading ? 2.05 : 1.35) + 16;
};

function mix(a: string, b: string, t: number): string {
  const p = (h: string) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const [x, y] = [p(a), p(b)];
  return `rgb(${x.map((v, i) => Math.round(v + (y[i] - v) * t)).join(",")})`;
}

function buildLines() {
  const box = $("lines");
  box.innerHTML = "";
  tokens = [];
  if (!song || song.timing === "none") { builtFor = song?.id ?? ""; return; }
  const h = rowHeight();
  song.lines.forEach((line, i) => {
    const t = lineTokens(line, store.tone);
    tokens.push(t);
    const el = document.createElement("div");
    el.className = "line";
    el.style.top = `${i * h}px`;
    el.style.height = `${h}px`;
    el.innerHTML = `<div class="zh">${t.map((k) => `<span>${esc(k.text)}</span>`).join("")}</div>` +
      (store.reading && t.some((k) => k.reading) ? `<div class="py">${t.filter((k) => k.reading).map((k) => `<span>${esc(k.reading!)}</span>`).join(" ")}</div>` : "");
    el.onclick = () => {
      const target = line.start - (song!.offset ?? 0) - store.lead - 0.2;
      invoke("media_control", { action: "seek", seconds: Math.max(0, target) });
      browse = null;
    };
    box.appendChild(el);
  });
  builtFor = song.id;
  lastCur = -2;
}

const esc = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));

function render() {
  const msg = $("message");
  if (song && song.timing !== "none") msg.innerHTML = "";
  else if (status === "searching") msg.innerHTML = "Finding lyrics…";
  else if (status === "notFound") msg.innerHTML = "No lyrics found<small>Open settings (the gear) to paste a 汽水音乐 share link</small>";
  else if (song) msg.innerHTML = "These lyrics have no timing<small>They can't light up</small>";
  else msg.innerHTML = "Play a song<small>Spotify · YouTube · NetEase · any player</small>";
  if ((song?.id ?? "") !== builtFor) buildLines();
}

function frame() {
  requestAnimationFrame(frame);
  // Playback controls and seek bar.
  const len = np?.duration ?? 0, now = songTime();
  $("t-now").textContent = clock(dragFrac !== null ? dragFrac * len : now);
  $("t-len").textContent = clock(len);
  const f = dragFrac ?? (len > 0 ? now / len : 0);
  ($("fill") as HTMLElement).style.width = `${f * 100}%`;
  ($("knob") as HTMLElement).style.left = `${f * 100}%`;
  $("play").innerHTML = np?.playing ? ICONS.pause : ICONS.play;

  if (!song || song.timing === "none") return;
  const t = lyricTime();
  const lines = song.lines;
  const cur = currentIndex(lines, t);
  const scrollCur = currentIndex(lines, t + 0.35);
  const focus = browse ?? Math.max(scrollCur, 0);
  const h = rowHeight(), stageH = $("stage").clientHeight;
  ($("lines") as HTMLElement).style.transform = `translateY(${stageH / 2 - h / 2 - focus * h}px)`;
  $("back-now").classList.toggle("hidden", browse === null);

  const els = $("lines").children;
  if (scrollCur !== lastCur) {
    for (let i = 0; i < els.length; i++) {
      const d = browse === null ? Math.min(3, Math.abs(i - Math.max(scrollCur, 0))) : 0;
      (els[i] as HTMLElement).className = "line" + (d ? ` d${d}` : "");
    }
    lastCur = scrollCur;
  }
  // Color the words of the lines around the one being sung.
  for (let i = Math.max(0, cur - 2); i <= Math.min(lines.length - 1, cur + 1); i++) {
    const el = els[i] as HTMLElement | undefined;
    if (!el) continue;
    const next = i + 1 < lines.length ? lines[i + 1].start : song.duration;
    const p = i < cur - 1 ? tokens[i].map(() => 1) : progress(lines[i], tokens[i], next, t, song.timing, "wholeLine");
    const zh = el.children[0].children, py = el.children[1]?.children;
    let r = 0;
    tokens[i].forEach((tok, k) => {
      const c = mix("#ffffff", store.hl, p[k] ?? 0);
      (zh[k] as HTMLElement).style.color = c;
      if (tok.reading && py?.[r]) { (py[r] as HTMLElement).style.color = c; r++; }
    });
  }
}

const clock = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

// ---------- seek bar ----------
let dragFrac: number | null = null;
function setupSeek() {
  const bar = $("bar");
  const frac = (e: PointerEvent) => Math.min(1, Math.max(0, (e.clientX - bar.getBoundingClientRect().left) / bar.clientWidth));
  bar.addEventListener("pointerdown", (e) => { bar.setPointerCapture(e.pointerId); dragFrac = frac(e); });
  bar.addEventListener("pointermove", (e) => { if (dragFrac !== null) dragFrac = frac(e); });
  bar.addEventListener("pointerup", (e) => {
    const f = frac(e);
    dragFrac = null;
    if (np?.duration) invoke("media_control", { action: "seek", seconds: f * np.duration });
  });
}

// ---------- settings panel ----------
function setupSettings() {
  const sw = $("swatches");
  const paintSwatches = () => {
    sw.innerHTML = "";
    for (const c of COLORS) {
      const b = document.createElement("div");
      b.className = "swatch" + (c === store.hl ? " on" : "");
      b.style.background = c;
      b.onclick = () => { store.hl = c; document.documentElement.style.setProperty("--hl", c); paintSwatches(); };
      sw.appendChild(b);
    }
  };
  paintSwatches();
  const tones = $("tones");
  const paintTones = () => {
    tones.innerHTML = "";
    for (const [v, label] of [["symbol", "yīn yuè"], ["num", "yin1 yue4"], ["none", "yin yue"]] as const) {
      const b = document.createElement("button");
      b.textContent = label;
      b.className = store.tone === v ? "on" : "";
      b.onclick = () => { store.tone = v; paintTones(); builtFor = ""; render(); };
      tones.appendChild(b);
    }
  };
  paintTones();
  const reading = $("show-reading") as HTMLInputElement;
  reading.checked = store.reading;
  reading.onchange = () => { store.reading = reading.checked; builtFor = ""; render(); };
  const lead = $("lead") as HTMLInputElement;
  lead.value = String(store.lead);
  $("lead-v").textContent = `${store.lead >= 0 ? "+" : ""}${store.lead.toFixed(2)} s`;
  lead.oninput = () => { store.lead = Number(lead.value); $("lead-v").textContent = `${store.lead >= 0 ? "+" : ""}${store.lead.toFixed(2)} s`; };
  $("gear").onclick = () => $("settings").classList.toggle("hidden");
  $("qs-go").onclick = async () => {
    const msg = $("qs-msg");
    msg.textContent = "Getting lyrics from 汽水音乐…";
    try {
      const s = await qishui(fetchText, (url) => invoke<string>("resolve_link", { url }), ($("qs-link") as HTMLInputElement).value);
      if (!s) { msg.textContent = "That link didn't have lyrics."; return; }
      if (np) { const key = songKey(np.title, np.artist); if (s.id !== key) s.aliases = [...(s.aliases ?? []), key]; }
      await save(s);
      lastKey = ""; await trackChanged();
      msg.textContent = `Saved ${s.title}.`;
    } catch { msg.textContent = "Couldn't reach 汽水音乐."; }
  };
}

// ---------- start ----------
async function main() {
  document.documentElement.style.setProperty("--hl", store.hl);
  for (const id of ["prev", "next", "pin", "gear", "close"]) $(id).innerHTML = ICONS[id];
  $("prev").onclick = () => invoke("media_control", { action: "previous" });
  $("next").onclick = () => invoke("media_control", { action: "next" });
  $("play").onclick = () => invoke("media_control", { action: "toggle" });
  const win = getCurrentWindow();
  const paintPin = () => $("pin").classList.toggle("on", store.onTop);
  paintPin();
  await win.setAlwaysOnTop(store.onTop);
  $("pin").onclick = async () => { store.onTop = !store.onTop; await win.setAlwaysOnTop(store.onTop); paintPin(); };
  $("close").onclick = () => win.close();
  $("back-now").onclick = () => { browse = null; };
  $("stage").addEventListener("wheel", (e) => {
    if (!song) return;
    const cur = Math.max(0, currentIndex(song.lines, lyricTime()));
    const next = Math.min(song.lines.length - 1, Math.max(0, (browse ?? cur) + e.deltaY / rowHeight()));
    browse = browse !== null && Math.abs(next - cur) < 0.3 ? null : next;
  }, { passive: true });
  setupSeek();
  setupSettings();

  songs = (await invoke<string[]>("load_songs")).flatMap((t) => { try { return [JSON.parse(t)]; } catch { return []; } });
  await listen<NowPlaying | null>("now-playing", (e) => { np = e.payload; trackChanged(); });
  render();
  requestAnimationFrame(frame);
}
main();
