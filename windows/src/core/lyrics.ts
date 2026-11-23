// Lyric files: LRC (with enhanced word tags), NetEase YRC, 汽水音乐 KRC, and plain text.
// Ported from the Mac app's LyricsParser.swift.

export interface LyricWord { text: string; start: number; duration: number }
export interface LyricLine { start: number; text: string; words?: LyricWord[]; pinyinOverride?: string[] }
export type Timing = "word" | "line" | "none";

const lineTag = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/g;

export function parseLRC(text: string): LyricLine[] {
  const out: LyricLine[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("{")) continue; // NetEase credit metadata
    const tags = [...line.matchAll(lineTag)];
    if (tags.length === 0) continue;
    const last = tags[tags.length - 1];
    const body = line.slice(last.index! + last[0].length);
    const { plain, words } = enhancedWords(body);
    const clean = plain.trim();
    for (const m of tags) {
      const t = Number(m[1]) * 60 + Number(m[2].replace(":", "."));
      out.push({ start: t, text: clean, words });
    }
  }
  return out.filter((l) => l.text).sort((a, b) => a.start - b.start);
}

function enhancedWords(body: string): { plain: string; words?: LyricWord[] } {
  const tags = [...body.matchAll(/<(\d{1,3}):(\d{1,2}(?:\.\d{1,3})?)>/g)];
  if (tags.length === 0) return { plain: body };
  const words: LyricWord[] = [];
  let plain = "";
  tags.forEach((m, i) => {
    const t = Number(m[1]) * 60 + Number(m[2]);
    const from = m.index! + m[0].length;
    const to = i + 1 < tags.length ? tags[i + 1].index! : body.length;
    const w = body.slice(from, to);
    plain += w;
    if (w) words.push({ text: w, start: t, duration: 0 });
  });
  // Each word lasts until the next one starts.
  words.forEach((w, i) => {
    const next = i + 1 < words.length ? words[i + 1].start : w.start + 0.6;
    w.duration = Math.max(0.05, next - w.start);
  });
  return { plain, words: words.length ? words : undefined };
}

/** NetEase YRC: `[startMs,durMs](wordStartMs,wordDurMs,0)word…` (word times are absolute). */
export function parseYRC(text: string): LyricLine[] {
  return parseTimedWords(text, /\((\d+),(\d+),-?\d+\)([^(]*)/g, false);
}

/** 汽水音乐 KRC: `[lineStartMs,lineDurMs]<offsetMs,durMs,0>字…` (word times relative to the line). */
export function parseKRC(text: string): LyricLine[] {
  return parseTimedWords(text, /<(\d+),(\d+),-?\d+>([^<]*)/g, true);
}

function parseTimedWords(text: string, wordRe: RegExp, relative: boolean): LyricLine[] {
  const out: LyricLine[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const head = raw.match(/^\[(\d+),(\d+)\]/);
    if (!head) continue;
    const start = Number(head[1]) / 1000;
    const words: LyricWord[] = [];
    for (const m of raw.matchAll(wordRe)) {
      const s = Number(m[1]) / 1000, d = Number(m[2]) / 1000;
      if (m[3]) words.push({ text: m[3], start: relative ? start + s : s, duration: Math.max(0.05, d) });
    }
    const line = words.map((w) => w.text).join("").trim();
    if (line) out.push({ start, text: line, words });
  }
  return out.sort((a, b) => a.start - b.start);
}

export function parsePlain(text: string): LyricLine[] {
  return text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).map((t) => ({ start: 0, text: t }));
}

/** Picks the right parser for pasted lyrics. */
export function parsePasted(text: string): { lines: LyricLine[]; timing: Timing } {
  const lrc = parseLRC(text);
  if (lrc.length) return { lines: lrc, timing: lrc.some((l) => l.words) ? "word" : "line" };
  const yrc = parseYRC(text);
  if (yrc.length) return { lines: yrc, timing: "word" };
  const krc = parseKRC(text);
  if (krc.length) return { lines: krc, timing: "word" };
  return { lines: parsePlain(text), timing: "none" };
}
