// The English-letter reading under each line: pinyin for Chinese, romanization for Korean.
// (Japanese kanji need a dictionary on Windows; that comes in a later version.)
import { pinyin } from "pinyin-pro";
import type { Token } from "./karaoke.ts";
import { hasHangul, koreanTokens } from "./korean.ts";
import type { LyricLine } from "./lyrics.ts";

export type ToneStyle = "symbol" | "num" | "none";

export function tokens(text: string, tone: ToneStyle = "symbol"): Token[] {
  if (hasHangul(text)) return koreanTokens(text);
  const out: Token[] = [];
  for (const x of pinyin(text, { type: "all", toneType: tone }) as { origin: string; pinyin: string; isZh: boolean }[]) {
    if (!x.isZh && out.length && out[out.length - 1].reading === undefined) out[out.length - 1].text += x.origin;
    else out.push({ text: x.origin, reading: x.isZh ? x.pinyin : undefined });
  }
  return out;
}

/** Tokens for a line, using the user's own fixes where they made them. */
export function lineTokens(line: LyricLine, tone: ToneStyle = "symbol"): Token[] {
  const t = tokens(line.text, tone);
  if (line.pinyinOverride) {
    let i = 0;
    for (const tok of t) if (tok.reading !== undefined) { const fix = line.pinyinOverride[i++]; if (fix) tok.reading = fix; }
  }
  return t;
}
