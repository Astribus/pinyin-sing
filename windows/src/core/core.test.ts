import { test } from "node:test";
import assert from "node:assert/strict";
import { parseLRC, parseKRC, parseYRC, parsePasted } from "./lyrics.ts";
import { cleanArtist, cleanTitle, searchVariants, sameArtist } from "./titles.ts";
import { progress, currentIndex } from "./karaoke.ts";
import { romanizeWord, koreanTokens } from "./korean.ts";
import { tokens } from "./reading.ts";

test("LRC with several tags and enhanced words", () => {
  const l = parseLRC("[00:12.50][01:00.00]hello\n[00:05.00]<00:05.00>我<00:05.40>们");
  assert.equal(l.length, 3);
  assert.equal(l[0].text, "我们");
  assert.equal(l[0].words?.length, 2);
  assert.equal(l[1].start, 12.5);
});

test("KRC word times are relative to the line", () => {
  const l = parseKRC("[60,1470]<0,350,0>不<400,340,0>敢");
  assert.equal(l[0].text, "不敢");
  assert.equal(l[0].words![1].start, 0.06 + 0.4);
});

test("YRC word times are absolute", () => {
  const l = parseYRC("[1000,2000](1000,300,0)我(1300,300,0)们");
  assert.equal(l[0].words![1].start, 1.3);
});

test("pasted plain text has no timing", () => {
  assert.equal(parsePasted("一行\n两行").timing, "none");
});

test("titles and artists", () => {
  assert.equal(cleanArtist("Cindy Dong - Topic"), "Cindy Dong");
  assert.equal(cleanTitle("晴天 (Official MV) 【高清】"), "晴天");
  assert.deepEqual(searchVariants("忘记呼吸_晓晓"), ["忘记呼吸_晓晓", "忘记呼吸"]);
  assert.ok(sameArtist("胖虎(董欣怡), 牧言 MuYan", ["胖虎（董欣怡）", "牧言"]));
  assert.ok(!sameArtist("周杰伦", ["米叔啊"]));
});

test("karaoke fill and current line", () => {
  const line = { start: 10, text: "我们", words: [{ text: "我", start: 10, duration: 0.5 }, { text: "们", start: 10.5, duration: 0.5 }] };
  const toks = tokens("我们");
  assert.deepEqual(progress(line, toks, 12, 10.2, "word", "wholeLine"), [1, 0]);
  assert.equal(currentIndex([{ start: 0, text: "a" }, { start: 5, text: "b" }], 6), 1);
});

test("Korean romanization matches the Mac app", () => {
  assert.equal(romanizeWord("사랑해요"), "saranghaeyo");
  assert.equal(romanizeWord("잠이"), "jami");
  assert.equal(romanizeWord("반딧불을"), "banditbureul");
  assert.equal(romanizeWord("그날의"), "geunarui");
  assert.equal(romanizeWord("봄날"), "bomnal");
  assert.deepEqual(koreanTokens("이 밤").map((t) => t.reading), ["i", undefined, "bam"]);
});

test("pinyin reads words in context", () => {
  assert.deepEqual(tokens("银行").map((t) => t.reading), ["yín", "háng"]);
});
