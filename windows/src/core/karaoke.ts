// How "sung" each token of a line is at time t (0 = white, 1 = full color). Ported from Karaoke.swift.
import type { LyricLine, Timing } from "./lyrics.ts";

export interface Token { text: string; reading?: string }
export type LineFill = "wholeLine" | "sweep";

const notSpace = (s: string) => [...s].filter((c) => !/\s/.test(c));

export function progress(line: LyricLine, tokens: Token[], next: number | undefined, t: number,
                         timing: Timing, fill: LineFill): number[] {
  if (timing === "none") return tokens.map(() => 0);
  let charTimes: [number, number][];
  if (line.words?.length) {
    charTimes = [];
    for (const w of line.words) {
      const chars = notSpace(w.text);
      const each = w.duration / Math.max(chars.length, 1);
      chars.forEach((_, i) => charTimes.push([w.start + each * i, each]));
    }
  } else {
    const n = notSpace(line.text).length;
    const end = next ?? line.start + 5;
    if (fill === "wholeLine") {
      // A quick 0.12 s fade-in from the line's start.
      const v = Math.min(1, Math.max(0, (t - line.start) / 0.12));
      return tokens.map(() => v);
    }
    // About 3 characters a second; don't stretch over an instrumental gap.
    const span = Math.min(Math.max(0.4, (end - line.start) * 0.85), n * 0.32 + 0.25);
    const each = span / Math.max(n, 1);
    charTimes = Array.from({ length: n }, (_, i) => [line.start + each * i, each]);
  }
  // A character fills within 0.18 s of its start, so it reads as "now".
  const quick = charTimes.map(([s, d]) => [s, Math.min(d, 0.18)] as [number, number]);
  const out: number[] = [];
  let i = 0;
  for (const tok of tokens) {
    let sum = 0, count = 0;
    for (const _ of notSpace(tok.text)) {
      if (i < quick.length) {
        const [s, d] = quick[i];
        sum += d <= 0 ? (t >= s ? 1 : 0) : Math.min(1, Math.max(0, (t - s) / d));
      } else {
        sum += Math.min(1, Math.max(0, (t - line.start) / 0.12));
      }
      count++; i++;
    }
    out.push(count === 0 ? (out[out.length - 1] ?? 0) : sum / count);
  }
  return out;
}

/** Index of the line being sung at time t (-1 before the first line). */
export function currentIndex(lines: LyricLine[], t: number): number {
  let lo = 0, hi = lines.length - 1, ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].start <= t) { ans = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return ans;
}
