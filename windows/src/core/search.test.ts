// Live check against the real lyric services (skipped without network).
import { test } from "node:test";
import assert from "node:assert/strict";
import { find, match } from "./search.ts";

const fetchText = async (url: string, referer?: string) => {
  const r = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0 PinyinSing-test", ...(referer ? { Referer: referer } : {}) } });
  return r.text();
};

test("finds 我们没有说话 on NetEase with the 汽水音乐 artist spelling", async () => {
  const s = await find(fetchText, { title: "我们没有说话", artist: "胖虎(董欣怡), 牧言 MuYan", duration: 196 });
  assert.equal(s?.source, "NetEase");
  assert.ok((s?.lines.length ?? 0) > 50);
});

test("matches a saved song played in another app by title and length", () => {
  const saved = [{ id: "晴天|周杰伦", title: "晴天", artist: "周杰伦", duration: 269, source: "x", timing: "line" as const, lines: [], savedAt: "", offset: 0 }];
  assert.equal(match(saved, { title: "晴天", artist: "Jay Chou - Topic", duration: 268.5 })?.fuzzy, true);
});
