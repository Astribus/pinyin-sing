// Saved songs, albums (Liked Songs first) and cover art, shared by both windows.
// Same file format as the Mac app. Any change is announced so the other window reloads.
import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import type { SavedSong as BaseSong } from "../core/search.ts";

export interface SavedSong extends BaseSong {
  app?: string; apps?: string[]; links?: Record<string, string>; neteaseID?: number;
  playCount?: number; lastPlayed?: string;
}
export interface Album { id: string; name: string; songIDs: string[]; created: string }

export const LIKED = "00000000-0000-0000-0000-000000000001";

export const library = {
  songs: [] as SavedSong[],
  albums: [] as Album[],
  art: new Map<string, string>(),
};

export async function loadLibrary() {
  library.songs = (await invoke<string[]>("load_songs"))
    .flatMap((t) => { try { return [JSON.parse(t) as SavedSong]; } catch { return []; } })
    .sort((a, b) => (b.savedAt ?? "").localeCompare(a.savedAt ?? ""));
  let albums: Album[] = [];
  try { albums = JSON.parse(await invoke<string>("load_albums")); } catch { /* none yet */ }
  if (!albums.some((a) => a.id === LIKED)) albums.unshift({ id: LIKED, name: "Liked Songs", songIDs: [], created: new Date().toISOString() });
  albums.sort((a, b) => (a.id === LIKED ? -1 : b.id === LIKED ? 1 : 0));
  library.albums = albums;
}

const changed = () => emit("library-changed");
export const onLibraryChange = (fn: () => void) => listen("library-changed", async () => { await loadLibrary(); fn(); });

export async function saveSong(s: SavedSong) {
  const i = library.songs.findIndex((x) => x.id === s.id);
  if (i >= 0) library.songs[i] = s; else library.songs.unshift(s);
  await invoke("save_song", { id: s.id, json: JSON.stringify(s) });
  await changed();
}

export async function deleteSong(s: SavedSong) {
  library.songs = library.songs.filter((x) => x.id !== s.id);
  for (const a of library.albums) a.songIDs = a.songIDs.filter((id) => id !== s.id);
  await invoke("delete_song", { id: s.id });
  await saveAlbums();
}

export async function saveAlbums() {
  await invoke("save_albums", { json: JSON.stringify(library.albums) });
  await changed();
}

export const isLiked = (id: string) => library.albums[0]?.songIDs.includes(id) ?? false;
export async function toggleLike(id: string) {
  const liked = library.albums.find((a) => a.id === LIKED)!;
  liked.songIDs = isLiked(id) ? liked.songIDs.filter((x) => x !== id) : [id, ...liked.songIDs];
  await saveAlbums();
}
export async function toggleInAlbum(songID: string, albumID: string) {
  const a = library.albums.find((x) => x.id === albumID);
  if (!a) return;
  a.songIDs = a.songIDs.includes(songID) ? a.songIDs.filter((x) => x !== songID) : [...a.songIDs, songID];
  await saveAlbums();
}
export async function newAlbum(name: string, songID?: string): Promise<Album> {
  const a: Album = { id: crypto.randomUUID().toUpperCase(), name, songIDs: songID ? [songID] : [], created: new Date().toISOString() };
  library.albums.push(a);
  await saveAlbums();
  return a;
}
export async function renameAlbum(id: string, name: string) {
  const a = library.albums.find((x) => x.id === id);
  if (a && id !== LIKED) { a.name = name; await saveAlbums(); }
}
export async function deleteAlbum(id: string) {
  if (id === LIKED) return;
  library.albums = library.albums.filter((a) => a.id !== id);
  await saveAlbums();
}
export const songsIn = (a: Album) => a.songIDs.flatMap((id) => library.songs.filter((s) => s.id === id));

export async function artFor(id: string): Promise<string | undefined> {
  if (library.art.has(id)) return library.art.get(id);
  const a = await invoke<string | null>("load_art", { id });
  if (a) library.art.set(id, a);
  return a ?? undefined;
}
export async function saveArt(id: string, dataUrl: string) {
  if (!dataUrl || library.art.has(id)) return;
  library.art.set(id, dataUrl);
  await invoke("save_art", { id, dataUrl });
}

// ---------- platforms (which service a song was played on) ----------
/** Windows reports the player's app id; this turns it into a platform like the Mac app's. */
export function platformFor(appId: string): string {
  const a = appId.toLowerCase();
  if (a.includes("spotify")) return "spotify";
  if (a.includes("cloudmusic") || a.includes("netease")) return "netease";
  if (a.includes("soda") || a.includes("qishui") || a.includes("汽水")) return "qishui";
  if (a.includes("applemusic") || a.includes("itunes")) return "applemusic";
  if (/chrome|msedge|firefox|brave|opera|vivaldi|arc/.test(a)) return "browser";
  return a || "unknown";
}
export function platformName(p: string): string {
  return ({ qishui: "汽水音乐", netease: "NetEase", spotify: "Spotify", youtube: "YouTube", applemusic: "Apple Music",
            browser: "Browser" } as Record<string, string>)[p] ?? p;
}
export const platforms = (s: SavedSong) => [...new Set([s.app, ...(s.apps ?? [])].filter(Boolean) as string[])];

/** Notes a play: the platform it played on (songs can belong to several), count and time. */
export function played(s: SavedSong, platform: string): SavedSong {
  const t = { ...s, playCount: (s.playCount ?? 0) + 1, lastPlayed: new Date().toISOString() };
  if (platform !== "unknown") {
    t.app = platform;
    if (!(t.apps ?? []).includes(platform)) t.apps = [...(t.apps ?? []), platform];
  }
  return t;
}
