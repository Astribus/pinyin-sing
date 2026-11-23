// Korean → English letters the way it's sung (Revised Romanization + main sound rules).
// Ported from Romanize.swift: 사랑해요 → saranghaeyo, 잠이 → jami, 반딧불을 → banditbureul.
import type { Token } from "./karaoke.ts";

export const hasHangul = (s: string) => /[가-힣]/.test(s);

const initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"];
const medials = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"];
const finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"];
const carried = ["", "g", "kk", "ks", "n", "nj", "n", "d", "r", "lg", "lm", "lb", "ls", "lt", "lp", "r", "m", "b", "ps", "s", "ss", "", "j", "ch", "k", "t", "p", ""];
const kSound = new Set([1, 2, 3, 9, 24]), tSound = new Set([7, 19, 20, 22, 23, 25, 27]), pSound = new Set([17, 18, 14, 26, 11]);

export function romanizeWord(word: string): string {
  const chars = [...word];
  const syl = chars.map((c) => {
    const u = c.codePointAt(0)!;
    if (u < 0xac00 || u > 0xd7a3) return null;
    const i = u - 0xac00;
    return { initial: Math.floor(i / 588), medial: Math.floor((i % 588) / 28), final: i % 28 };
  });
  let out = "";
  for (let k = 0; k < syl.length; k++) {
    const s = syl[k];
    if (!s) { out += chars[k]; continue; }
    out += initials[s.initial] + medials[s.medial];
    if (s.final === 0) continue;
    const n = syl[k + 1];
    if (!n) { out += finals[s.final]; continue; }
    const f = s.final, ni = n.initial;
    if (ni === 11 && f !== 21) { out += carried[f]; continue; }                         // final carries over
    if (f === 27 && [0, 3, 12].includes(ni)) { n.initial = ni === 0 ? 15 : ni === 3 ? 16 : 14; continue; }
    if (ni === 18 && (kSound.has(f) || pSound.has(f) || tSound.has(f))) {
      n.initial = kSound.has(f) ? 15 : pSound.has(f) ? 17 : 16; continue;
    }
    if (ni === 2 || ni === 6) {                                                          // nasal sounds
      if (kSound.has(f)) { out += "ng"; continue; }
      if (tSound.has(f)) { out += "n"; continue; }
      if (pSound.has(f)) { out += "m"; continue; }
      if (f === 8 && ni === 2) { out += "l"; n.initial = 5; continue; }
    }
    if (ni === 5) {                                                                      // before ㄹ
      if (f === 8 || f === 4) { out += "l"; n.initial = 5; continue; }
      if (f === 16 || f === 21) { out += finals[f]; n.initial = 2; continue; }
      if (kSound.has(f)) { out += "ng"; n.initial = 2; continue; }
      if (pSound.has(f)) { out += "m"; n.initial = 2; continue; }
    }
    out += finals[f];
  }
  return out.replace(/lr/g, "ll");
}

/** One token per word, with its reading; spaces and punctuation stay as tokens with no reading. */
export function koreanTokens(text: string): Token[] {
  const out: Token[] = [];
  for (const part of text.split(/(\s+|[^\p{L}\p{N}]+)/u)) {
    if (!part) continue;
    if (hasHangul(part)) out.push({ text: part, reading: romanizeWord(part) });
    else if (out.length && out[out.length - 1].reading === undefined) out[out.length - 1].text += part;
    else out.push({ text: part });
  }
  return out;
}
