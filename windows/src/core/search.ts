// Finds timed lyrics for what's playing: NetEase first, then LRCLIB. Ported from the Mac app's
// LyricsService / NetEaseSource / LRCLIBSource / Qishui. Network access is passed in, so this
// file runs (and is tested) without Tauri.
import { parseKRC, parseLRC, parseYRC, type LyricLine, type Timing } from "./lyrics.ts";
import { artistParts, cleanArtist, cleanTitle, sameArtist, searchVariants, songKey } from "./titles.ts";

export interface Track { title: string; artist: string; duration: number; app?: string }
export interface SavedSong {
  id: string; title: string; artist: string; duration?: number; source: string; timing: Timing;
  lines: LyricLine[]; savedAt: string; offset: number; aliases?: string[];
}
export type Fetch = (url: string, referer?: string) => Promise<string>;

interface NESong { id: number; name: string; artists: { name: string }[]; duration?: number }

function score(s: NESong, title: string, artist: string, duration: number): number {
  let v = 0;
  const n = s.name.toLowerCase(), t = title.toLowerCase();
  if (n === t) v += 3; else if (n.includes(t) || t.includes(n)) v += 1.5;
  if (sameArtist(artist, s.artists.map((a) => a.name))) v += 2;
  if (duration > 0 && s.duration) {
    const diff = Math.abs(s.duration / 1000 - duration);
    if (diff < 3) v += 2; else if (diff < 10) v += 1; else if (diff > 30) v -= 1;
  }
  return v;
}

export async function netease(fetch: Fetch, title: string, artist: string, duration: number): Promise<SavedSong | null> {
  const parts = artistParts(artist);
  const short = parts.find((p) => !p.includes("(")) ?? parts[0] ?? "";
  const songs: NESong[] = [];
  for (const q of [...new Set([`${title} ${short}`.trim(), title])]) {
    try {
      const r = JSON.parse(await fetch(`https://music.163.com/api/search/get?s=${encodeURIComponent(q)}&type=1&limit=15`, "https://music.163.com"));
      for (const s of r?.result?.songs ?? []) if (!songs.some((x) => x.id === s.id)) songs.push(s);
    } catch { /* try the next query */ }
  }
  if (!songs.length) return null;
  const best = songs.reduce((a, b) => (score(b, title, artist, duration) > score(a, title, artist, duration) ? b : a));
  if (score(best, title, artist, duration) <= 1) return null;
  // Same title by another singer is usually a cover with different timing: only if the length matches.
  if (artist && !sameArtist(artist, best.artists.map((a) => a.name))) {
    if (!(duration > 0 && best.duration && Math.abs(best.duration / 1000 - duration) < 2 && best.name.toLowerCase() === title.toLowerCase())) return null;
  }
  const lyr = JSON.parse(await fetch(`https://music.163.com/api/song/lyric?id=${best.id}&lv=1&yv=1&tv=-1`, "https://music.163.com"));
  const base = { id: "", title: best.name, artist: best.artists[0]?.name ?? artist, duration: (best.duration ?? 0) / 1000,
                 source: "NetEase", savedAt: new Date().toISOString(), offset: 0 };
  const yrc = lyr?.yrc?.lyric ? parseYRC(lyr.yrc.lyric) : [];
  if (yrc.length) return { ...base, timing: "word", lines: yrc };
  const lrc = lyr?.lrc?.lyric ? parseLRC(lyr.lrc.lyric) : [];
  if (lrc.length > 2) return { ...base, timing: lrc.some((l) => l.words) ? "word" : "line", lines: lrc };
  return null;
}

export async function lrclib(fetch: Fetch, title: string, artist: string, duration: number): Promise<SavedSong | null> {
  let url = `https://lrclib.net/api/search?track_name=${encodeURIComponent(title)}`;
  if (artist) url += `&artist_name=${encodeURIComponent(artist)}`;
  const items: { trackName?: string; artistName?: string; duration?: number; syncedLyrics?: string }[] = JSON.parse(await fetch(url));
  const synced = items.filter((i) => i.syncedLyrics);
  if (!synced.length) return null;
  const best = synced.reduce((a, b) => (Math.abs((b.duration ?? 0) - duration) < Math.abs((a.duration ?? 0) - duration) ? b : a));
  if (duration > 0 && best.duration && Math.abs(best.duration - duration) > 15) return null;
  const lines = parseLRC(best.syncedLyrics!);
  if (lines.length <= 2) return null;
  return { id: "", title: best.trackName ?? title, artist: best.artistName ?? artist, duration: best.duration, source: "LRCLIB",
           timing: lines.some((l) => l.words) ? "word" : "line", lines, savedAt: new Date().toISOString(), offset: 0 };
}

/** Looks everywhere, trying shorter versions of the title if the full one finds nothing. */
export async function find(fetch: Fetch, track: Track): Promise<SavedSong | null> {
  const artist = cleanArtist(track.artist);
  for (const title of searchVariants(track.title)) {
    for (const source of [netease, lrclib]) {
      try {
        const s = await source(fetch, title, artist, track.duration);
        if (s) return { ...s, id: songKey(track.title, track.artist), title: cleanTitle(track.title), artist, duration: track.duration || s.duration };
      } catch { /* next source */ }
    }
  }
  return null;
}

/** A 汽水音乐 share link (or track id) → its lyrics, timed for every character. */
export async function qishui(fetch: Fetch, resolve: (url: string) => Promise<string>, link: string): Promise<SavedSong | null> {
  const t = link.trim();
  let id = t.match(/^(\d{17,20})$/)?.[1] ?? t.match(/track_id=(\d{10,})/)?.[1] ?? t.match(/\/track\/(\d{10,})/)?.[1];
  if (!id) {
    const url = t.match(/(https?:\/\/[^\s，。]+)/)?.[1];
    if (!url) return null;
    const final = await resolve(url);
    id = final.match(/track_id=(\d{10,})/)?.[1] ?? final.match(/\/track\/(\d{10,})/)?.[1];
  }
  if (!id) return null;
  const page = JSON.parse(await fetch(`https://beta-luna.douyin.com/luna/h5/seo_track?device_platform=web&track_id=${id}`));
  const track = page?.seo_track?.track, content = page?.lyric?.content;
  if (!track || !content) return null;
  const lines = page.lyric.type === "krc" ? parseKRC(content) : parseLRC(content);
  if (!lines.length) return null;
  const artist = (track.artists ?? []).map((a: { name: string }) => a.name).join(" / ");
  return { id: songKey(track.name, artist), title: track.name, artist, duration: (track.duration ?? 0) / 1000 || undefined,
           source: "汽水音乐", timing: lines.some((l) => l.words) ? "word" : "line", lines, savedAt: new Date().toISOString(), offset: 0 };
}

/** A saved song for this track: same title and artist, a known alias, or same title and length (±2 s). */
export function match(songs: SavedSong[], track: Track): { song: SavedSong; fuzzy: boolean } | null {
  const key = songKey(track.title, track.artist);
  const exact = songs.find((s) => s.id === key || s.aliases?.includes(key));
  if (exact) return { song: exact, fuzzy: false };
  if (!(track.duration > 0)) return null;
  const titles = new Set(searchVariants(track.title).map((t) => t.toLowerCase()));
  const hit = songs.find((s) => s.duration && Math.abs(s.duration - track.duration) < 2 && titles.has(s.title.toLowerCase()));
  return hit ? { song: hit, fuzzy: true } : null;
}
