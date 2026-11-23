// The scrolling karaoke lyrics, used by the island, the Home card and the Now Playing page.
import { currentIndex, progress, type Token } from "../core/karaoke.ts";
import { lineTokens } from "../core/reading.ts";
import type { SavedSong } from "./library.ts";
import { colors, mix, settings } from "./settings.ts";

const esc = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));

export class LyricsStage {
  private lines: HTMLElement;
  private back: HTMLElement;
  private song: SavedSong | null = null;
  private tokens: Token[][] = [];
  private builtKey = "";
  private lastFocus = -2;
  browse: number | null = null;

  /** `root` gets the lines; `onSeek` jumps the player to a lyric time. */
  constructor(private root: HTMLElement, private onSeek: (lyricTime: number) => void, private time: () => number) {
    root.classList.add("stage");
    this.lines = document.createElement("div");
    this.lines.className = "lines";
    this.back = document.createElement("button");
    this.back.className = "back-now hidden";
    this.back.textContent = "Back to now";
    this.back.onclick = (e) => { e.stopPropagation(); this.browse = null; };
    root.append(this.lines, this.back);
    root.addEventListener("wheel", (e) => {
      if (!this.song) return;
      const cur = Math.max(0, currentIndex(this.song.lines, this.time()));
      const next = Math.min(this.song.lines.length - 1, Math.max(0, (this.browse ?? cur) + e.deltaY / this.rowHeight()));
      this.browse = this.browse !== null && Math.abs(next - cur) < 0.3 ? null : next;
    }, { passive: true });
  }

  rowHeight() { return settings.fontSize * (settings.reading ? 2.05 : 1.35) + 16; }

  setSong(song: SavedSong | null) {
    const key = song ? `${song.id}|${settings.tone}|${settings.reading}|${settings.fontSize}|${song.lines.map((l) => l.pinyinOverride?.join("") ?? "").join()}` : "";
    if (key === this.builtKey) { this.song = song; return; }
    this.song = song;
    this.builtKey = key;
    this.browse = null;
    this.lines.innerHTML = "";
    this.tokens = [];
    this.lastFocus = -2;
    if (!song || song.timing === "none") return;
    const h = this.rowHeight();
    song.lines.forEach((line, i) => {
      const t = lineTokens(line, settings.tone);
      this.tokens.push(t);
      const el = document.createElement("div");
      el.className = "line";
      el.style.top = `${i * h}px`;
      el.style.height = `${h}px`;
      const reading = settings.reading && t.some((k) => k.reading)
        ? `<div class="py">${t.filter((k) => k.reading).map((k) => `<span>${esc(k.reading!)}</span>`).join(" ")}</div>` : "";
      el.innerHTML = `<div class="zh">${t.map((k) => `<span>${esc(k.text)}</span>`).join("")}</div>${reading}`;
      el.onclick = (e) => { e.stopPropagation(); this.browse = null; this.onSeek(line.start); };
      this.lines.appendChild(el);
    });
  }

  /** Call every frame. */
  frame() {
    const song = this.song;
    if (!song || song.timing === "none") return;
    const t = this.time(), lines = song.lines;
    const cur = currentIndex(lines, t);
    const scrollCur = currentIndex(lines, t + 0.35);   // scroll a little before the line starts
    const focus = this.browse ?? Math.max(scrollCur, 0);
    const h = this.rowHeight();
    this.lines.style.transform = `translateY(${this.root.clientHeight / 2 - h / 2 - focus * h}px)`;
    this.back.classList.toggle("hidden", this.browse === null);
    const els = this.lines.children;
    if (Math.round(focus) !== this.lastFocus) {
      for (let i = 0; i < els.length; i++) {
        const d = this.browse === null ? Math.min(3, Math.abs(i - Math.max(scrollCur, 0))) : 0;
        (els[i] as HTMLElement).className = "line" + (d ? ` d${d}` : "");
      }
      this.lastFocus = Math.round(focus);
    }
    const hl = colors().highlight;
    for (let i = Math.max(0, cur - 2); i <= Math.min(lines.length - 1, cur + 1); i++) {
      const el = els[i] as HTMLElement | undefined;
      if (!el) continue;
      const next = i + 1 < lines.length ? lines[i + 1].start : song.duration;
      const p = i < cur - 1 ? this.tokens[i].map(() => 1) : progress(lines[i], this.tokens[i], next, t, song.timing, settings.lineFill);
      const zh = el.children[0].children, py = el.children[1]?.children;
      let r = 0;
      this.tokens[i].forEach((tok, k) => {
        const c = mix("#ffffff", hl, p[k] ?? 0);
        (zh[k] as HTMLElement).style.color = c;
        if (tok.reading && py?.[r]) { (py[r] as HTMLElement).style.color = c; r++; }
      });
    }
  }
}
