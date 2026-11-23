// The lyrics island. It also decides which saved song is playing (finding lyrics when there are
// none) and tells the dashboard, so both windows show the same thing.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { parsePasted } from "./core/lyrics.ts";
import { find, match, qishui } from "./core/search.ts";
import { cleanArtist, cleanTitle, songKey } from "./core/titles.ts";
import { isLiked, library, loadLibrary, onLibraryChange, platformFor, played, saveArt, saveSong, toggleLike, type SavedSong } from "./shared/library.ts";
import { ICONS, announceSong, control, lyricTime, onNowPlaying, playback, seekBar, seekLyric } from "./shared/playback.ts";
import { albumPicker, notice } from "./shared/popups.ts";
import { applyTheme, averageColor, onSettingsChange, settings } from "./shared/settings.ts";
import { LyricsStage } from "./shared/stage.ts";

const $ = (id: string) => document.getElementById(id)!;
const fetchText = (url: string, referer?: string) => invoke<string>("fetch_text", { url, referer: referer ?? null });
let song: SavedSong | null = null;
let lastKey = "";

const current = () => (playback.songID ? library.songs.find((s) => s.id === playback.songID) ?? null : null);
const stage = new LyricsStage($("stage"), (t) => seekLyric(t, song?.offset ?? 0), () => lyricTime(song?.offset ?? 0));

async function setCurrent(s: SavedSong | null, status: typeof playback.status) {
  song = s;
  playback.songID = s?.id ?? null;
  playback.status = status;
  await announceSong();
  render();
}

async function trackChanged() {
  const np = playback.np;
  if (np?.art) {
    const c = await averageColor(np.art);
    if (c && c !== settings.artColor) { settings.artColor = c; applyTheme(); }
  }
  if (!np) { lastKey = ""; await setCurrent(null, "idle"); return; }
  const key = songKey(np.title, np.artist);
  if (song && np.art) await saveArt(song.id, np.art);
  if (key === lastKey) return;
  lastKey = key;
  const platform = platformFor(np.app);
  const hit = match(library.songs, { title: np.title, artist: np.artist, duration: np.duration });
  if (hit) {
    let s = played(hit.song, platform);
    if (hit.fuzzy) s = { ...s, aliases: [...(s.aliases ?? []), key] };
    await saveSong(s);
    if (np.art) await saveArt(s.id, np.art);
    await setCurrent(s, "found");
    return;
  }
  await setCurrent(null, "searching");
  const found = await find(fetchText, { title: np.title, artist: np.artist, duration: np.duration });
  if (lastKey !== key) return;
  if (found) {
    const s = played(found, platform);
    await saveSong(s);
    if (np.art) await saveArt(s.id, np.art);
    await setCurrent(s, "found");
  } else await setCurrent(null, "notFound");
}

function render() {
  const msg = $("message");
  if (song && song.timing !== "none") msg.innerHTML = "";
  else if (playback.status === "searching") msg.innerHTML = "Finding lyrics…";
  else if (playback.status === "notFound") msg.innerHTML = "No lyrics found<small>Open the island settings (the gear) to paste a 汽水音乐 link or the lyrics</small>";
  else if (song) msg.innerHTML = "These lyrics have no timing<small>They can't light up</small>";
  else msg.innerHTML = "Play a song<small>Spotify · YouTube · NetEase · any player</small>";
  stage.setSong(song);
  $("like").classList.toggle("hidden", !song);
  $("add").classList.toggle("hidden", !song);
  $("like").innerHTML = song && isLiked(song.id) ? ICONS.heartFill : ICONS.heart;
  $("like").classList.toggle("liked", !!song && isLiked(song.id));
}

let drawSeek: () => void = () => {};
function frame() {
  requestAnimationFrame(frame);
  drawSeek();
  $("play").innerHTML = playback.np?.playing ? ICONS.pause : ICONS.play;
  stage.frame();
}

async function saveFor(s: SavedSong | null, msg: string) {
  if (!s) return;
  const np = playback.np;
  if (np) {
    const key = songKey(np.title, np.artist);
    s = { ...s, id: key, title: cleanTitle(np.title), artist: cleanArtist(np.artist), duration: np.duration || s.duration,
          aliases: s.id !== key ? [s.id] : undefined };
    s = played(s, platformFor(np.app));
  }
  await saveSong(s);
  lastKey = "";
  await trackChanged();
  notice(msg, s.title);
}

async function main() {
  applyTheme();
  onSettingsChange(() => { applyTheme(); stage.setSong(song); });
  for (const id of ["prev", "next", "pin", "gear", "hide"]) $(id).innerHTML = ICONS[id === "hide" ? "close" : id];
  $("dash").innerHTML = ICONS.library;
  $("add").innerHTML = ICONS.plus;
  drawSeek = seekBar($("seek"));
  $("prev").onclick = () => control("previous");
  $("next").onclick = () => control("next");
  $("play").onclick = () => control("toggle");
  const win = getCurrentWindow();
  const paintPin = () => $("pin").classList.toggle("on", settings.onTop);
  paintPin();
  await win.setAlwaysOnTop(settings.onTop);
  $("pin").onclick = async () => { settings.onTop = !settings.onTop; await win.setAlwaysOnTop(settings.onTop); paintPin(); };
  $("hide").onclick = () => invoke("set_island", { shown: false });
  $("dash").onclick = () => invoke("open_dashboard");
  $("gear").onclick = () => $("settings").classList.toggle("hidden");
  $("like").onclick = async () => { if (song) { await toggleLike(song.id); render(); } };
  $("add").onclick = () => {
    if (!song) return;
    $("island").classList.add("picking");
    albumPicker($("add"), song.id, () => {});
    const stop = () => { $("island").classList.remove("picking"); removeEventListener("click", stop, true); };
    setTimeout(() => addEventListener("click", stop, true), 0);
  };
  $("qs-go").onclick = async () => {
    const msg = $("qs-msg");
    msg.textContent = "Getting lyrics from 汽水音乐…";
    try {
      const s = await qishui(fetchText, (url) => invoke<string>("resolve_link", { url }), ($("qs-link") as HTMLInputElement).value);
      if (!s) { msg.textContent = "That link didn't have lyrics."; return; }
      msg.textContent = "";
      $("settings").classList.add("hidden");
      await saveFor(s as SavedSong, "Saved from 汽水音乐");
    } catch { msg.textContent = "Couldn't reach 汽水音乐."; }
  };
  $("paste-go").onclick = async () => {
    const text = ($("paste") as HTMLTextAreaElement).value;
    const { lines, timing } = parsePasted(text);
    if (!lines.length || !playback.np) return;
    $("settings").classList.add("hidden");
    await saveFor({ id: "", title: playback.np.title, artist: playback.np.artist, duration: playback.np.duration, source: "Pasted",
                    timing, lines, savedAt: new Date().toISOString(), offset: 0 }, "Lyrics saved");
  };

  await loadLibrary();
  await onLibraryChange(() => { song = current() ?? song; render(); });
  await onNowPlaying(trackChanged);
  // The dashboard saved new lyrics (pasted, 汽水音乐 link, search again): look the song up again.
  await listen("refresh-track", async () => { await loadLibrary(); lastKey = ""; await trackChanged(); });
  render();
  requestAnimationFrame(frame);
}
main();
