// Cleaning up titles and artists the way players report them. Ported from Models.swift / LyricsService.swift.

export function cleanArtist(s: string): string {
  const a = s.trim();
  return a.endsWith(" - Topic") ? a.slice(0, -8) : a;
}

export function cleanTitle(s: string): string {
  let t = s;
  for (const p of [/\((?:official|mv|lyric|audio|music video|live|动态歌词|歌词)[^)]*\)/gi, /【[^】]*】/g, /\[[^\]]*\]/g, /「|」|《|》/g]) {
    t = t.replace(p, " ");
  }
  return t.replace(/\s+/g, " ").trim();
}

/** Shorter guesses to search with when the full title finds nothing. */
export function searchVariants(s: string): string[] {
  const base = cleanTitle(s);
  const out = [base];
  for (const sep of ["_", " - ", "-", "（", "("]) {
    const i = base.indexOf(sep);
    if (i > 0) {
      const head = base.slice(0, i).trim();
      if (head && !out.includes(head)) out.push(head);
    }
  }
  return out;
}

export function songKey(title: string, artist: string): string {
  return `${cleanTitle(title).toLowerCase()}|${cleanArtist(artist).toLowerCase()}`;
}

/** "胖虎(董欣怡), 牧言 MuYan" → comparable names (half-width, lowercased, split, with and without brackets). */
export function artistParts(s: string): string[] {
  const half = s.normalize("NFKC").toLowerCase();
  const pieces = half.replace(/\s*(,|\/|&|、|;|\bfeat\.?|\bft\.?|\bx\b)\s*/g, "|").split("|").map((p) => p.trim()).filter(Boolean);
  const out: string[] = [];
  for (const p of pieces) {
    out.push(p);
    const bare = p.replace(/\([^)]*\)/g, "").trim();
    if (bare && bare !== p) out.push(bare);
    const first = p.split(" ")[0];
    if (first.length < p.length) out.push(first);
  }
  return out;
}

export function sameArtist(artist: string, names: string[]): boolean {
  const mine = artistParts(artist), theirs = names.flatMap(artistParts);
  return mine.some((m) => theirs.some((t) => m === t || (m.length > 1 && t.includes(m)) || (t.length > 1 && m.includes(t))));
}
