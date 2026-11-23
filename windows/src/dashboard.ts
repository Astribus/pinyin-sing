// The dashboard: Home, Now Playing, the library (all songs, per app, albums), song pages with
// pinyin editing, Customization and Settings. The island decides what's playing; this follows.
import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { openUrl } from "@tauri-apps/plugin-opener";
import { parsePasted } from "./core/lyrics.ts";
import { lineTokens } from "./core/reading.ts";
import { qishui } from "./core/search.ts";
import { cleanArtist, cleanTitle, songKey } from "./core/titles.ts";
import { LIKED, artFor, deleteAlbum, deleteSong, isLiked, library, loadLibrary, onLibraryChange, platformFor, platformName,
         platforms, played, renameAlbum, saveSong, songsIn, toggleLike, newAlbum, type Album, type SavedSong } from "./shared/library.ts";
import { ICONS, clock, control, lyricTime, onCurrentSong, onNowPlaying, playback, seekBar, seekLyric } from "./shared/playback.ts";
import { albumPicker, confirm, menu, notice, prompt } from "./shared/popups.ts";
import { THEMES, applyTheme, mix, onSettingsChange, settings } from "./shared/settings.ts";
import { LyricsStage } from "./shared/stage.ts";

type Page = { kind: "home" } | { kind: "now" } | { kind: "songs"; app?: string } | { kind: "album"; id: string }
  | { kind: "song"; id: string } | { kind: "custom" } | { kind: "settings" };

let page: Page = { kind: "home" };
let islandShown = false;
let query = "";
const $ = (s: string) => document.querySelector(s) as HTMLElement;
const esc = (s: string) => (s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const fetchText = (url: string, referer?: string) => invoke<string>("fetch_text", { url, referer: referer ?? null });
const current = () => (playback.songID ? library.songs.find((s) => s.id === playback.songID) ?? null : null);

// ---------- live parts (redrawn every frame) ----------
let stages: LyricsStage[] = [];
let seekDrawers: (() => void)[] = [];
function frame() {
  requestAnimationFrame(frame);
  seekDrawers.forEach((d) => d());
  stages.forEach((s) => s.frame());
  document.querySelectorAll<HTMLElement>("[data-playicon]").forEach((b) => (b.innerHTML = playback.np?.playing ? ICONS.pause : ICONS.play));
}

// ---------- sidebar ----------
function appsInLibrary(): string[] {
  const counts = new Map<string, number>();
  for (const s of library.songs) for (const p of platforms(s)) counts.set(p, (counts.get(p) ?? 0) + 1);
  return [...counts.keys()].sort((a, b) => counts.get(b)! - counts.get(a)! || platformName(a).localeCompare(platformName(b)));
}
const same = (a: Page, b: Page) => JSON.stringify(a) === JSON.stringify(b);

function drawSidebar() {
  const row = (p: Page, label: string, icon: string, count?: number) =>
    `<button class="nav-row ${same(page, p) ? "on" : ""}" data-page='${esc(JSON.stringify(p))}'><span class="ni">${icon}</span>${esc(label)}${count ? `<span class="count">${count}</span>` : ""}</button>`;
  $("#sidebar").innerHTML = `
    <div class="brand"><img src="icon.png" alt=""><b>音乐</b></div>
    <div class="nav">
      ${row({ kind: "home" }, "Home", ICONS.library)}
      ${row({ kind: "now" }, "Now Playing", ICONS.play)}
      <div class="nav-head">LIBRARY</div>
      ${row({ kind: "songs" }, "All Songs", ICONS.library, library.songs.length)}
      ${appsInLibrary().map((a) => row({ kind: "songs", app: a }, platformName(a), ICONS.play, library.songs.filter((s) => platforms(s).includes(a)).length)).join("")}
      <div class="nav-head">ALBUMS</div>
      ${library.albums.map((a) => row({ kind: "album", id: a.id }, a.name, a.id === LIKED ? ICONS.heartFill : ICONS.library, a.songIDs.length)).join("")}
      <button class="nav-row nav-add" id="new-album"><span class="ni">${ICONS.plus}</span>New Album</button>
      <div class="nav-head">APP</div>
      ${row({ kind: "custom" }, "Customization", ICONS.gear)}
      ${row({ kind: "settings" }, "Settings", ICONS.gear)}
    </div>
    <div class="side-foot">
      <div class="island-switch"><div>Lyrics island<small>${islandShown ? "Showing" : "Hidden"}</small></div>
        <button class="switch ${islandShown ? "on" : ""}" id="island-toggle" title="Show or hide the lyrics island"></button></div>
    </div>`;
  document.querySelectorAll<HTMLElement>("[data-page]").forEach((b) => (b.onclick = () => go(JSON.parse(b.dataset.page!))));
  $("#new-album").onclick = () => prompt("New album", [{ label: "Album name", value: "" }], "Create", async ([n]) => {
    const a = await newAlbum(n); go({ kind: "album", id: a.id }); notice("Album created", n);
  });
  $("#island-toggle").onclick = () => invoke("set_island", { shown: !islandShown });
}

function go(p: Page) { page = p; query = ""; draw(); $("#page").scrollTop = 0; }

// ---------- pieces ----------
function coverHTML(s: { id: string; title: string } | null, cls = "cover") {
  const letter = esc([...(s?.title ?? "♪")][0] ?? "♪");
  return `<div class="${cls}" data-art="${esc(s?.id ?? "")}">${letter}</div>`;
}
async function fillArt(root: ParentNode = document) {
  for (const el of root.querySelectorAll<HTMLElement>("[data-art]")) {
    const id = el.dataset.art!;
    const src = id === "__now" ? playback.np?.art : id ? await artFor(id) : undefined;
    if (src && !el.querySelector("img")) el.insertAdjacentHTML("beforeend", `<img src="${src}" alt="">`);
  }
}

function songCard(s: SavedSong, inAlbum?: Album) {
  return `<div class="song" data-song="${esc(s.id)}" data-album="${esc(inAlbum?.id ?? "")}">
    <div style="position:relative">${coverHTML(s)}
      <button class="ov play" data-act="play" title="Play">${ICONS.play}</button>
      <button class="ov add" data-act="add" title="Add to album">${ICONS.plus}</button>
      <button class="ov heart ${isLiked(s.id) ? "on keep" : ""}" data-act="like" title="Like">${isLiked(s.id) ? ICONS.heartFill : ICONS.heart}</button></div>
    <div class="meta"><div><div class="t">${esc(s.title)}</div><div class="a">${esc(s.artist)}</div>
      <div class="p">${esc(platforms(s).map(platformName).join(" · "))}</div></div>
      <button class="more" data-act="more" title="More">${ICONS.more}</button></div></div>`;
}

function wireSongs(root: ParentNode) {
  root.querySelectorAll<HTMLElement>(".song").forEach((card) => {
    const s = () => library.songs.find((x) => x.id === card.dataset.song)!;
    card.onclick = (e) => {
      const act = (e.target as HTMLElement).closest<HTMLElement>("[data-act]")?.dataset.act;
      const btn = (e.target as HTMLElement).closest<HTMLElement>("[data-act]")!;
      if (!act) return go({ kind: "song", id: s().id });
      e.stopPropagation();
      if (act === "play") playSong(s());
      if (act === "like") toggleLike(s().id).then(draw);
      if (act === "add") albumPicker(btn, s().id, draw);
      if (act === "more") songMenu(btn, s(), library.albums.find((a) => a.id === card.dataset.album));
    };
  });
}

function songMenu(anchor: HTMLElement, s: SavedSong, inAlbum?: Album) {
  menu(anchor, [
    { icon: ICONS.play, label: s.app ? `Play in ${platformName(s.app)}` : "Play", action: () => playSong(s) },
    { icon: ICONS.library, label: "Lyrics & Pinyin", action: () => go({ kind: "song", id: s.id }) },
    { icon: isLiked(s.id) ? ICONS.heart : ICONS.heartFill, label: isLiked(s.id) ? "Remove from Liked Songs" : "Add to Liked Songs", action: () => toggleLike(s.id).then(draw) },
    { icon: ICONS.plus, label: "Add to Album…", action: () => albumPicker(anchor, s.id, draw) },
    ...(inAlbum && inAlbum.id !== LIKED ? [{ icon: ICONS.close, label: `Remove from ${inAlbum.name}`, action: async () => {
      inAlbum.songIDs = inAlbum.songIDs.filter((x) => x !== s.id); const { saveAlbums } = await import("./shared/library.ts"); await saveAlbums(); draw(); } }] : []),
    { icon: "", label: "-", action: () => {} },
    { icon: ICONS.gear, label: "Edit Title & Artist…", action: () => prompt("Edit song", [{ label: "Title", value: s.title }, { label: "Artist", value: s.artist }], "Save",
        async ([t, a]) => { await saveSong({ ...s, title: t, artist: a || s.artist }); draw(); }, "This only changes how it's shown here.") },
    { icon: ICONS.close, label: "Delete…", danger: true, action: () => confirm(`Delete ${s.title}?`, "Its saved lyrics and pinyin fixes are removed.", "Delete",
        async () => { await deleteSong(s); if (page.kind === "song") go({ kind: "songs" }); else draw(); }) },
  ]);
}

/** Opens a saved song where it was last played. */
async function playSong(s: SavedSong) {
  const q = encodeURIComponent(`${s.title} ${s.artist}`);
  const p = s.app ?? "youtube";
  try {
    if (p === "spotify") await openUrl(`spotify:search:${q}`);
    else if (p === "youtube" || p === "browser") await openUrl(s.links?.youtube ?? `https://www.youtube.com/results?search_query=${q}`);
    else if (p === "netease") {
      const r = JSON.parse(await fetchText(`https://music.163.com/api/search/get?s=${q}&type=1&limit=1`, "https://music.163.com"));
      const id = r?.result?.songs?.[0]?.id;
      await openUrl(id ? `orpheus://${btoa(JSON.stringify({ type: "song", id: String(id), cmd: "play" }))}` : `https://music.163.com/#/search/m/?s=${q}`);
    } else {
      await writeText(`${s.title} ${s.artist}`);
      notice(`Copied "${s.title}"`, `${platformName(p)} can't be told which song to play. Paste it into its search.`);
      return;
    }
    notice(`Opening in ${platformName(p)}…`);
  } catch { notice("Couldn't open it", platformName(p)); }
}

// ---------- pages ----------
function homePage() {
  const s = current(), np = playback.np;
  const h = new Date().getHours();
  const greeting = h < 5 ? "Late night listening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
  const recent = library.songs.filter((x) => x.lastPlayed).sort((a, b) => b.lastPlayed!.localeCompare(a.lastPlayed!)).slice(0, 12);
  const most = library.songs.filter((x) => (x.playCount ?? 0) > 1).sort((a, b) => (b.playCount ?? 0) - (a.playCount ?? 0)).slice(0, 12);
  const chars = new Set(library.songs.flatMap((x) => x.lines.flatMap((l) => [...l.text].filter((c) => /[㐀-鿿]/.test(c))))).size;
  const shelf = (title: string, list: SavedSong[], empty?: string) => list.length || empty
    ? `<h2>${title}</h2>${list.length ? `<div class="shelf">${list.map((x) => songCard(x)).join("")}</div>` : `<div class="empty">${empty}</div>`}` : "";
  return `<div class="date">${new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" }).toUpperCase()}</div>
    <h1>${greeting}</h1>
    <div class="hero card">${coverHTML(np ? { id: "__now", title: np.title } : null)}
      <div class="info">
        <div class="pill-label">${np ? `NOW PLAYING · ${esc(platformName(platformFor(np.app)))}` : "NOTHING PLAYING"}</div>
        <div class="title">${esc(np ? cleanTitle(np.title) : "Play a song in any music app")}</div>
        ${np ? `<div class="artist">${esc(cleanArtist(np.artist))}</div>` : ""}
        ${s ? `<div class="live" id="live"></div>` : ""}
        ${np ? `<div id="hero-seek"></div>` : ""}
        <div class="buttons">
          ${np ? `<button class="ctrl" data-c="previous">${ICONS.prev}</button><button class="ctrl main" data-c="toggle" data-playicon></button><button class="ctrl" data-c="next">${ICONS.next}</button>` : ""}
          ${s ? `<button class="gbtn ${isLiked(s.id) ? "liked" : ""}" id="h-like">${isLiked(s.id) ? ICONS.heartFill : ICONS.heart}${isLiked(s.id) ? "Liked" : "Like"}</button>
                 <button class="gbtn" id="h-add">${ICONS.plus}Add to Album</button>` : ""}
          ${np ? `<button class="gbtn" id="h-full">Full lyrics</button>` : ""}
          <button class="gbtn" id="h-island">${islandShown ? "Hide island" : "Show island"}</button>
        </div></div></div>
    <div class="stats">
      <div class="stat card"><i>${ICONS.library}</i><div><b>${library.songs.length}</b><small>songs</small></div></div>
      <div class="stat card"><i>字</i><div><b>${chars}</b><small>characters</small></div></div>
      <div class="stat card"><i>${ICONS.play}</i><div><b>${appsInLibrary().length}</b><small>apps</small></div></div>
      <div class="stat card"><i>${ICONS.gear}</i><div><b>${library.songs.reduce((n, x) => n + x.lines.filter((l) => l.pinyinOverride).length, 0)}</b><small>pinyin fixes</small></div></div>
    </div>
    ${shelf("Jump back in", recent, "Songs you play show up here.")}
    ${shelf("Most played", most)}
    <h2>Your albums</h2><div class="shelf">${library.albums.map((a) => albumTile(a)).join("")}</div>
    ${shelf("Needs better lyrics", library.songs.filter((x) => x.timing === "none"))}
    ${shelf("Recently added", library.songs.slice(0, 12))}`;
}

function albumTile(a: Album) {
  const first = songsIn(a)[0];
  const art = a.id === LIKED ? `<div class="cover" style="background:linear-gradient(135deg,#ff5e8a,#8a5cff)">${ICONS.heartFill}</div>` : coverHTML(first ?? { id: "", title: a.name });
  return `<div class="song" data-albumtile="${esc(a.id)}">${art}<div class="t">${esc(a.name)}</div><div class="a">${a.songIDs.length} songs</div></div>`;
}

function nowPage() {
  const s = current(), np = playback.np;
  return `<div class="page-head">${coverHTML(np ? { id: "__now", title: np.title } : null)}
      <div style="display:flex;flex-direction:column;gap:6px;flex:1;min-width:260px">
        <div class="date">${np ? `NOW PLAYING · ${esc(platformName(platformFor(np.app)))}` : "NOTHING PLAYING"}</div>
        <div class="title">${esc(np ? cleanTitle(np.title) : "Play a song in any music app")}</div>
        ${np ? `<div class="artist">${esc(cleanArtist(np.artist))}</div>` : ""}
        ${s ? `<div class="chip">${esc(s.source)} · ${s.timing === "word" ? "word-by-word timing" : s.timing === "line" ? "line timing" : "no timing"}</div>
          <div class="buttons"><button class="gbtn ${isLiked(s.id) ? "liked" : ""}" id="h-like">${isLiked(s.id) ? ICONS.heartFill : ICONS.heart}${isLiked(s.id) ? "Liked" : "Like"}</button>
          <button class="gbtn" id="h-add">${ICONS.plus}Add to Album</button></div>` : ""}
      </div>
      <div class="buttons" style="flex-direction:column;align-items:flex-end">
        <button class="gbtn" id="h-island">${islandShown ? "Hide island" : "Show island"}</button>
        ${np ? `<button class="gbtn" id="n-retry">Search again</button><button class="gbtn" id="n-paste">Paste lyrics</button>` : ""}
      </div></div>
    ${np ? `<div id="hero-seek"></div>` : ""}
    ${np && playback.status === "notFound" ? `<div class="card" style="padding:18px;margin-top:18px"><b>No lyrics found online</b>
      <div class="dlg-note" style="margin:8px 0;color:var(--muted)">Playing it in 汽水音乐? Click Share → Copy Link on the song and paste it here. The lyrics come with a time for every character.</div>
      <div class="buttons"><input class="search" style="margin:0;flex:1" id="qs" placeholder="Paste a 汽水音乐 link"><button class="gbtn" id="qs-go">Get lyrics</button></div></div>` : ""}
    <div class="big-stage" id="big"></div>`;
}

function songsPage(app?: string) {
  let list = app ? library.songs.filter((s) => platforms(s).includes(app)) : library.songs;
  if (query) list = list.filter((s) => `${s.title} ${s.artist}`.toLowerCase().includes(query.toLowerCase()));
  return `<div class="page-head"><div><h1 style="margin:0">${esc(app ? platformName(app) : "All Songs")}</h1>
      ${app ? `<div style="color:var(--muted)">Songs you've played on ${esc(platformName(app))}</div>` : ""}</div>
      <input class="search" id="q" placeholder="Search" value="${esc(query)}"></div>
    ${list.length ? `<div class="grid">${list.map((s) => songCard(s)).join("")}</div>` : `<div class="empty">${library.songs.length ? "No matches." : "Songs show up here once their lyrics are found."}</div>`}`;
}

function albumPage(id: string) {
  const a = library.albums.find((x) => x.id === id);
  if (!a) return `<div class="empty">This album was deleted.</div>`;
  const list = songsIn(a);
  return `<div class="page-head"><div style="width:170px">${albumTile(a).replace(/<div class="t">.*$/s, "</div>")}</div>
      <div style="display:flex;flex-direction:column;gap:8px"><div class="date">ALBUM</div><h1 style="margin:0">${esc(a.name)}</h1>
      <div style="color:var(--muted)">${list.length} songs</div>
      <div class="buttons">${list[0] ? `<button class="gbtn" id="a-play">${ICONS.play}Play</button>` : ""}
        ${a.id !== LIKED ? `<button class="gbtn" id="a-more">${ICONS.more}</button>` : ""}</div></div></div>
    ${list.length ? `<div class="grid">${list.map((s) => songCard(s, a)).join("")}</div>`
      : `<div class="empty">${a.id === LIKED ? "Tap the heart on any song to add it here." : "Add songs with the + on any song."}</div>`}`;
}

let editing = -1;
function songPage(id: string) {
  const s = library.songs.find((x) => x.id === id);
  if (!s) return `<div class="empty">This song was deleted.</div>`;
  return `<button class="gbtn" id="back">← Back</button>
    <div class="page-head" style="margin-top:18px">${coverHTML(s).replace('class="cover"', 'class="cover" style="width:150px"')}
      <div style="display:flex;flex-direction:column;gap:6px"><div class="title">${esc(s.title)}</div><div class="artist">${esc(s.artist)}</div>
        <div class="chip">${esc(s.source)} · ${s.lines.length} lines</div>
        ${platforms(s).length ? `<small style="color:var(--muted)">on ${esc(platforms(s).map(platformName).join(" · "))}</small>` : ""}
        <div class="buttons"><button class="gbtn" id="s-play">${ICONS.play}${s.app ? `Play in ${esc(platformName(s.app))}` : "Play"}</button>
          <button class="gbtn" id="s-add">${ICONS.plus}Add to Album</button><button class="gbtn" id="s-more">${ICONS.more}</button></div></div></div>
    <div class="banner">✎<div><b>Pinyin is made automatically, so it can be wrong.</b><div style="font-size:13px">Click any line below to fix it. Your fixes are saved with the song.</div></div></div>
    ${s.timing !== "none" ? `<div class="buttons" style="margin-bottom:10px">Timing shift: <b>${s.offset >= 0 ? "+" : ""}${s.offset.toFixed(2)} s</b>
      <button class="gbtn" data-shift="-0.25">− 0.25</button><button class="gbtn" data-shift="0.25">+ 0.25</button></div>` : ""}
    <div class="rows">${s.lines.map((l, i) => {
      const toks = lineTokens(l, settings.tone), rd = toks.filter((t) => t.reading).map((t) => t.reading!);
      return `<div class="lrow" data-line="${i}"><span class="tm">${s.timing !== "none" ? clock(l.start) : ""}</span><span class="tx">${esc(l.text)}</span>${l.pinyinOverride ? `<span class="edited">edited</span>` : ""}
        ${editing === i ? `<div style="padding-left:48px;margin-top:6px" class="buttons"><input class="search" style="margin:0;flex:1" id="ed" value="${esc(rd.join(" "))}">
          <button class="gbtn" id="ed-save">Save</button><button class="gbtn" id="ed-cancel">Cancel</button>${l.pinyinOverride ? `<button class="gbtn" id="ed-reset">Reset</button>` : ""}</div>
          <div style="padding-left:48px;font-size:12px;color:var(--muted)">${rd.length} readings, one per character, separated by spaces</div>`
          : `<div class="rd">${esc(rd.join(" "))}</div>`}</div>`; }).join("")}</div>`;
}

function customPage() {
  const pills = (opts: [string, string][], cur: string, key: string) =>
    `<div class="pills">${opts.map(([v, l]) => `<button class="${cur === v ? "on" : ""}" data-set="${key}" data-v="${v}">${esc(l)}</button>`).join("")}</div>`;
  return `<h1>Customization</h1><div style="color:var(--muted);margin:-20px 0 10px">Pick a look. Every theme is tuned for both the dashboard and the lyrics island.</div>
    <h2>Theme</h2><div class="themes">${THEMES.map((t) => {
      const art = t.followsArt && settings.artColor ? settings.artColor : "";
      const p = art || t.primary, s = art ? mix(art, "#000000", 0.3) : t.secondary;
      return `<div class="theme card ${settings.theme.id === t.id ? "on" : ""}" data-theme="${t.id}"><div class="pv">
        <i style="background:${p};left:-30px;top:-40px"></i><i style="background:${s};right:-30px;bottom:-40px"></i>
        <div class="isl" style="background:${t.island}"><span style="color:${t.highlight}">音乐</span>好听<small>yīn yuè hǎo tīng</small></div></div>
        <div class="nm">${t.name}${t.followsArt ? "<small>follows the song</small>" : ""}</div></div>`; }).join("")}</div>
    <h2>Appearance</h2><div class="tiles">${(["system", "light", "dark"] as const).map((m) =>
      `<div class="tile card ${settings.appearance === m ? "on" : ""}" data-appearance="${m}">${m[0].toUpperCase() + m.slice(1)}</div>`).join("")}</div>
    <h2>Lyrics island</h2><div class="card settings-card">
      <div class="srow"><div class="lbl">Pinyin style<small>Chinese only. Korean always shows its English-letter reading.</small></div>
        ${pills([["symbol", "yīn yuè"], ["num", "yin1 yue4"], ["none", "yin yue"]], settings.tone, "tone")}</div>
      <div class="srow"><div class="lbl">Show the reading under each line</div><button class="switch ${settings.reading ? "on" : ""}" data-toggle="reading"></button></div>
      <div class="srow"><div class="lbl">Text size</div><input type="range" min="18" max="40" value="${settings.fontSize}" data-range="fontSize"></div>
      <div class="srow"><div class="lbl">See-through<small>Solid → glass</small></div><input type="range" min="0" max="1" step="0.05" value="${settings.glass}" data-range="glass"></div>
      <div class="srow"><div class="lbl">Lines with no word timing</div>${pills([["wholeLine", "Whole line"], ["sweep", "Sweep"]], settings.lineFill, "lineFill")}</div>
    </div>`;
}

let draftLead: number | null = null;
function settingsPage() {
  const lead = draftLead ?? settings.lead;
  return `<h1>Settings</h1>
    <h2>Timing</h2><div class="card settings-card">
      <div class="srow"><div class="lbl">Light up earlier by<small>Applies right away, to the song playing now and every song after.</small></div>
        <input type="range" min="-0.5" max="0.8" step="0.05" value="${lead}" id="lead"><b style="width:60px">${lead >= 0 ? "+" : ""}${lead.toFixed(2)} s</b>
        <button class="gbtn" id="lead-apply" ${draftLead === null || draftLead === settings.lead ? "disabled style='opacity:.4'" : ""}>Apply</button></div></div>
    <h2>Lyrics island</h2><div class="card settings-card">
      <div class="srow"><div class="lbl">Keep it on top of other windows<small>Off: it acts like a normal window. The pin on the island switches this too.</small></div>
        <button class="switch ${settings.onTop ? "on" : ""}" data-toggle="onTop"></button></div></div>
    <h2>Feedback</h2><div class="card feedback"><b>Have an idea or found a bug?</b>
      <div style="color:var(--muted)">Message the developer on LinkedIn, or report it on GitHub so others can see it too.</div>
      <div class="buttons"><button class="gbtn" id="fb-li">Message on LinkedIn</button><button class="gbtn" id="fb-gh">Report on GitHub</button></div></div>`;
}

// ---------- drawing + wiring ----------
function draw() {
  applyTheme();
  drawSidebar();
  stages = []; seekDrawers = [];
  const html = page.kind === "home" ? homePage() : page.kind === "now" ? nowPage() : page.kind === "songs" ? songsPage(page.app)
    : page.kind === "album" ? albumPage(page.id) : page.kind === "song" ? songPage(page.id) : page.kind === "custom" ? customPage() : settingsPage();
  const root = $("#page");
  root.innerHTML = html;
  const s = current();
  const offset = () => current()?.offset ?? 0;
  for (const id of ["live", "big"]) {
    const el = document.getElementById(id);
    if (el && s) { const st = new LyricsStage(el, (t) => seekLyric(t, offset()), () => lyricTime(offset())); st.setSong(s); stages.push(st); }
  }
  const sk = document.getElementById("hero-seek");
  if (sk) seekDrawers.push(seekBar(sk));
  root.querySelectorAll<HTMLElement>("[data-c]").forEach((b) => (b.onclick = () => control(b.dataset.c as "toggle")));
  wireSongs(root);
  root.querySelectorAll<HTMLElement>("[data-albumtile]").forEach((t) => (t.onclick = () => go({ kind: "album", id: t.dataset.albumtile! })));
  const on = (id: string, fn: (el: HTMLElement) => void) => { const el = document.getElementById(id); if (el) el.onclick = () => fn(el); };
  on("h-like", () => s && toggleLike(s.id).then(draw));
  on("h-add", (el) => s && albumPicker(el, s.id, draw));
  on("h-full", () => go({ kind: "now" }));
  on("h-island", () => invoke("set_island", { shown: !islandShown }));
  on("n-retry", async () => { if (s) await deleteSong(s); await emit("refresh-track"); });
  on("n-paste", () => prompt("Paste lyrics", [{ label: "LRC lyrics (with [00:12.34] times) or plain text", value: "" }], "Save", async ([text]) => {
    const np = playback.np; const { lines, timing } = parsePasted(text);
    if (!np || !lines.length) return;
    await saveSong(played({ id: songKey(np.title, np.artist), title: cleanTitle(np.title), artist: cleanArtist(np.artist), duration: np.duration,
      source: "Pasted", timing, lines, savedAt: new Date().toISOString(), offset: 0 }, platformFor(np.app)));
    await emit("refresh-track"); notice("Lyrics saved");
  }));
  on("qs-go", async () => {
    const np = playback.np, link = (document.getElementById("qs") as HTMLInputElement).value;
    const q = await qishui(fetchText, (url) => invoke<string>("resolve_link", { url }), link).catch(() => null);
    if (!q || !np) { notice("That link didn't have lyrics"); return; }
    const key = songKey(np.title, np.artist);
    await saveSong(played({ ...q, id: key, title: cleanTitle(np.title), artist: cleanArtist(np.artist), duration: np.duration, aliases: q.id !== key ? [q.id] : undefined }, platformFor(np.app)));
    await emit("refresh-track"); notice("Saved from 汽水音乐", q.title);
  });
  const qi = document.getElementById("q") as HTMLInputElement | null;
  if (qi) qi.oninput = () => { query = qi.value; const pos = qi.selectionStart; draw(); const n = document.getElementById("q") as HTMLInputElement; n.focus(); n.setSelectionRange(pos, pos); };
  if (page.kind === "album") {
    const a = library.albums.find((x) => x.id === (page as { id: string }).id)!;
    on("a-play", () => playSong(songsIn(a)[0]));
    on("a-more", (el) => menu(el, [
      { icon: ICONS.gear, label: "Rename…", action: () => prompt("Rename album", [{ label: "Album name", value: a.name }], "Save", ([n]) => renameAlbum(a.id, n).then(draw)) },
      { icon: ICONS.close, label: "Delete Album", danger: true, action: () => deleteAlbum(a.id).then(() => go({ kind: "home" })) },
    ]));
  }
  if (page.kind === "song") wireSongPage(page.id);
  if (page.kind === "custom") wireCustom();
  if (page.kind === "settings") wireSettings();
  fillArt(root);
}

function wireSongPage(id: string) {
  const s = library.songs.find((x) => x.id === id);
  if (!s) return;
  const on = (sel: string, fn: (el: HTMLElement) => void) => { const el = document.getElementById(sel); if (el) el.onclick = (e) => { e.stopPropagation(); fn(el); }; };
  on("back", () => history.length && go({ kind: "songs" }));
  on("s-play", () => playSong(s));
  on("s-add", (el) => albumPicker(el, s.id, draw));
  on("s-more", (el) => songMenu(el, s));
  document.querySelectorAll<HTMLElement>("[data-shift]").forEach((b) => (b.onclick = async () => { await saveSong({ ...s, offset: s.offset + Number(b.dataset.shift) }); draw(); }));
  document.querySelectorAll<HTMLElement>(".lrow").forEach((r) => (r.onclick = () => { const i = Number(r.dataset.line); if (editing !== i) { editing = i; draw(); (document.getElementById("ed") as HTMLInputElement)?.focus(); } }));
  const setFix = async (v: string[] | undefined) => {
    const lines = s.lines.map((l, i) => (i === editing ? { ...l, pinyinOverride: v } : l));
    editing = -1; await saveSong({ ...s, lines }); draw();
  };
  on("ed-save", () => { const v = (document.getElementById("ed") as HTMLInputElement).value.split(/[\s,]+/).filter(Boolean); setFix(v.length ? v : undefined); });
  on("ed-cancel", () => { editing = -1; draw(); });
  on("ed-reset", () => setFix(undefined));
  const ed = document.getElementById("ed") as HTMLInputElement | null;
  if (ed) ed.onkeydown = (k) => { if (k.key === "Enter") document.getElementById("ed-save")!.click(); };
}

function wireCustom() {
  document.querySelectorAll<HTMLElement>("[data-theme]").forEach((t) => (t.onclick = () => { settings.themeID = t.dataset.theme!; draw(); }));
  document.querySelectorAll<HTMLElement>("[data-appearance]").forEach((t) => (t.onclick = () => { settings.appearance = t.dataset.appearance as "dark"; draw(); }));
  document.querySelectorAll<HTMLElement>("[data-set]").forEach((b) => (b.onclick = () => { (settings as Record<string, unknown>)[b.dataset.set!] = b.dataset.v; draw(); }));
  document.querySelectorAll<HTMLElement>("[data-toggle]").forEach((b) => (b.onclick = () => { const k = b.dataset.toggle as "reading"; settings[k] = !settings[k]; draw(); }));
  document.querySelectorAll<HTMLInputElement>("[data-range]").forEach((r) => (r.oninput = () => { (settings as Record<string, unknown>)[r.dataset.range!] = Number(r.value); applyTheme(); }));
}

function wireSettings() {
  const lead = document.getElementById("lead") as HTMLInputElement;
  lead.oninput = () => { draftLead = Number(lead.value); draw(); };
  document.getElementById("lead-apply")!.onclick = () => {
    if (draftLead === null) return;
    settings.lead = draftLead; notice("Lyrics timing applied", `Words now light up ${draftLead >= 0 ? "+" : ""}${draftLead.toFixed(2)} s early`);
    draftLead = null; draw();
  };
  document.querySelectorAll<HTMLElement>("[data-toggle]").forEach((b) => (b.onclick = () => { const k = b.dataset.toggle as "onTop"; settings[k] = !settings[k]; draw(); }));
  document.getElementById("fb-li")!.onclick = () => openUrl("https://www.linkedin.com/in/yue-chen-0aa274317/");
  document.getElementById("fb-gh")!.onclick = () => openUrl("https://github.com/Astribus/pinyin-sing/issues/new");
}

function backdrop() {
  const art = playback.np?.art;
  const bg = $("#art-bg");
  bg.style.backgroundImage = art ? `url("${art}")` : "none";
  bg.style.opacity = art ? "0.5" : "0";
}

async function main() {
  applyTheme();
  await loadLibrary();
  onSettingsChange(draw);
  await onLibraryChange(draw);
  await onCurrentSong(draw);
  let lastSong = "";
  await onNowPlaying(() => {
    backdrop();
    const key = playback.np ? `${playback.np.title}|${playback.np.artist}|${playback.np.art.length}` : "";
    if (key !== lastSong) { lastSong = key; if (page.kind === "home" || page.kind === "now") draw(); }
  });
  await listen<boolean>("island-shown", (e) => { islandShown = e.payload; draw(); });
  draw();
  requestAnimationFrame(frame);
}
main();
