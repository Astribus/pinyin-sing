// What's playing and the controls for it, shared by both windows.
import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { settings } from "./settings.ts";

export interface NowPlaying { title: string; artist: string; duration: number; position: number; updatedMs: number; playing: boolean; app: string; art: string }
export type Status = "idle" | "searching" | "found" | "notFound";

export const playback = { np: null as NowPlaying | null, songID: null as string | null, status: "idle" as Status };

/** Exact position in the song, worked out from the last report and the time since. */
export function songTime(now = Date.now()): number {
  const np = playback.np;
  if (!np) return 0;
  const p = np.position + (np.playing ? (now - np.updatedMs) / 1000 : 0);
  return Math.min(np.duration || Infinity, Math.max(0, p));
}
/** Position in lyric time (adds the song's own shift and the "light up earlier" lead). */
export const lyricTime = (offset = 0) => songTime() + offset + settings.lead;

export const control = (action: "toggle" | "next" | "previous") => invoke("media_control", { action });
export const seek = (seconds: number) => invoke("media_control", { action: "seek", seconds: Math.max(0, seconds) });
/** Jump to a lyric line (undoing the song's shift and the lead, plus a breath before it). */
export const seekLyric = (t: number, offset = 0) => seek(t - offset - settings.lead - 0.2);

export function onNowPlaying(fn: () => void) {
  return listen<NowPlaying | null>("now-playing", (e) => { playback.np = e.payload; fn(); });
}

/** The island decides which saved song is playing; the dashboard follows along. */
export const announceSong = () => emit("current-song", { id: playback.songID, status: playback.status });
export function onCurrentSong(fn: () => void) {
  return listen<{ id: string | null; status: Status }>("current-song", (e) => {
    playback.songID = e.payload.id; playback.status = e.payload.status; fn();
  });
}

export const clock = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

/** A seek bar: time played on the left, song length on the right; click or drag to jump. */
export function seekBar(host: HTMLElement) {
  host.classList.add("seek");
  host.innerHTML = `<span class="t-now">0:00</span><div class="bar"><div class="fill"></div><div class="knob"></div></div><span class="t-len">0:00</span>`;
  const bar = host.querySelector(".bar") as HTMLElement;
  let drag: number | null = null;
  const frac = (e: PointerEvent) => Math.min(1, Math.max(0, (e.clientX - bar.getBoundingClientRect().left) / bar.clientWidth));
  bar.addEventListener("pointerdown", (e) => { e.stopPropagation(); bar.setPointerCapture(e.pointerId); drag = frac(e); });
  bar.addEventListener("pointermove", (e) => { if (drag !== null) drag = frac(e); });
  bar.addEventListener("pointerup", (e) => { const f = frac(e); drag = null; if (playback.np?.duration) seek(f * playback.np.duration); });
  return () => {
    const len = playback.np?.duration ?? 0, now = songTime();
    const f = drag ?? (len > 0 ? now / len : 0);
    host.querySelector(".t-now")!.textContent = clock(drag !== null ? drag * len : now);
    host.querySelector(".t-len")!.textContent = clock(len);
    (host.querySelector(".fill") as HTMLElement).style.width = `${f * 100}%`;
    (host.querySelector(".knob") as HTMLElement).style.left = `${f * 100}%`;
    host.classList.toggle("disabled", !(len > 0));
  };
}

// Drawn icons (the same set everywhere; no emoji).
const svg = (d: string, fill = true) =>
  `<svg width="16" height="16" viewBox="0 0 24 24" ${fill ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"'}>${d}</svg>`;
export const ICONS: Record<string, string> = {
  prev: svg('<path d="M6 5h2v14H6zM20 5v14L9 12z"/>'),
  next: svg('<path d="M16 5h2v14h-2zM4 5v14l11-7z"/>'),
  play: svg('<path d="M7 4v16l13-8z"/>'),
  pause: svg('<path d="M6 4h4v16H6zM14 4h4v16h-4z"/>'),
  pin: svg('<path d="M16 3l5 5-3 1-4 4 1 5-2 2-4-4-5 5-1-1 5-5-4-4 2-2 5 1 4-4z"/>'),
  gear: svg('<circle cx="12" cy="12" r="3.2"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/>', false),
  close: svg('<path d="M6 6l12 12M18 6L6 18"/>', false),
  heart: svg('<path d="M12 20s-7-4.4-9-9a5 5 0 0 1 9-3 5 5 0 0 1 9 3c-2 4.6-9 9-9 9z"/>', false),
  heartFill: svg('<path d="M12 20s-7-4.4-9-9a5 5 0 0 1 9-3 5 5 0 0 1 9 3c-2 4.6-9 9-9 9z"/>'),
  plus: svg('<path d="M12 5v14M5 12h14"/>', false),
  library: svg('<path d="M4 4h4v16H4zM10 4h4v16h-4zM16.5 4.5l3.8-1 3.7 15.5-3.8 1z"/>'),
  more: svg('<circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/>'),
  check: svg('<path d="M5 12l5 5L20 7"/>', false),
};
