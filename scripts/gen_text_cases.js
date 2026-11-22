#!/usr/bin/env node
// Generates test/fixtures/text_cases.json: expected values of the JS string expressions that
// Readability.Text ports, computed by Node itself. Dev-time only; the JSON is committed.
//
//   node scripts/gen_text_cases.js > test/fixtures/text_cases.json
"use strict";

const COMMAS = /,|\u060C|\uFE50|\uFE10|\uFE11|\u2E41|\u2E34|\u2E32|\uFF0C/g;

// The relevant parts of Readability.js, copied verbatim.
const HTML_ESCAPE_MAP = { lt: "<", gt: ">", amp: "&", quot: '"', apos: "'" };

function unescapeHtmlEntities(str) {
  if (!str) {
    return str;
  }
  return str
    .replace(/&(quot|amp|apos|lt|gt);/g, function (_, tag) {
      return HTML_ESCAPE_MAP[tag];
    })
    .replace(/&#(?:x([0-9a-f]+)|([0-9]+));/gi, function (_, hex, numStr) {
      var num = parseInt(hex || numStr, hex ? 16 : 10);
      if (num == 0 || num > 0x10ffff || (num >= 0xd800 && num <= 0xdfff)) {
        num = 0xfffd;
      }
      return String.fromCodePoint(num);
    });
}

function textSimilarity(textA, textB) {
  var tokensA = textA.toLowerCase().split(/\W+/g).filter(Boolean);
  var tokensB = textB.toLowerCase().split(/\W+/g).filter(Boolean);
  if (!tokensA.length || !tokensB.length) {
    return 0;
  }
  var uniqTokensB = tokensB.filter(token => !tokensA.includes(token));
  var distanceB = uniqTokensB.join(" ").length / tokensB.join(" ").length;
  return 1 - distanceB;
}

// Deterministic PRNG (mulberry32) so the fixture is reproducible.
function rng(seed) {
  return function () {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = rng(71);
const pick = xs => xs[Math.floor(rand() * xs.length)];

// Every JS whitespace character, plus look-alikes that are NOT JS whitespace.
const WS = ["\t", "\n", "\v", "\f", "\r", " ", "\u00A0", "\u1680", "\u2000", "\u2005", "\u200A",
  "\u2028", "\u2029", "\u202F", "\u205F", "\u3000", "\uFEFF"];
const NOT_WS = ["\u0085", "\u200B", "\u180E", "\u2060", "\u0000"];
const CHARS = ["a", "Z", "_", "0", "9", ".", "#", "&", ";", ",", "\u060C", "\uFE50", "\uFE10", "\uFE11",
  "\u2E41", "\u2E34", "\u2E32", "\uFF0C", "\u00E9", "\u00DF", "\u65E5", "\u{1F600}", "\u{1D49C}", "\u0130", "\u212A", "-", "'"];

const handWritten = [
  "", " ", "  ", "a", " a ", "a  b", "a \n b", "a\nb", "\n\na\n\n", "a\u00A0\u00A0b", "\u00A0a\u00A0",
  "\uFEFFa\uFEFF", "\u0085a\u0085", "a\u0085\u0085b", "\u{1F600}", " \u{1F600} \u{1F600} ", "a\r\nb", "a\r\n\r\nb",
  "foo\n", "foo ", "foo", "#", "#a", "#\n", "#\r", "#\u2028", "#\u2029", "#\u0085", "##", " #a", "#\u{1F600}",
  "\u2028\u2029", "a,b", "a\uFF0Cb\u3001c", "a\u060Cb\uFE50c\uFE10d\uFE11e\u2E41f\u2E34g\u2E32h\uFF0Ci",
  "\t\v\f", "x\u3000\u3000y", "\u1680a\u205F", "\u200Ba\u200B", "\u180E",
];

function randomString() {
  const n = Math.floor(rand() * 12);
  let s = "";
  for (let i = 0; i < n; i++) {
    const r = rand();
    s += r < 0.35 ? pick(WS) : r < 0.42 ? pick(NOT_WS) : pick(CHARS);
  }
  return s;
}

const strings = handWritten.slice();
for (let i = 0; i < 400; i++) strings.push(randomString());

const text = strings.map(s => ({
  s,
  trim: s.trim(),
  length: s.length,
  normalize: s.replace(/\s{2,}/g, " "),
  inner_text_length: s.trim().replace(/\s{2,}/g, " ").length,
  word_count: s.split(/\s+/).length,
  split_ws: s.split(/\s+/),
  remove_ws: s.replace(/\s/g, ""),
  blank: /^\s*$/.test(s),
  has_content: /\S$/.test(s),
  hash_url: /^#.+/.test(s),
  commas: s.split(",").length - 1,
  all_commas: s.split(COMMAS).length - 1,
}));

const entityInputs = [
  "", "plain", "&amp;", "&amp;amp;", "&AMP;", "&lt;&gt;&quot;&apos;", "&nbsp;", "&copy;", "&amp",
  "&#65;", "&#x41;", "&#X41;", "&#x4a;", "&#x4A;", "&#0;", "&#x0;", "&#xD800;", "&#xDFFF;", "&#xd7ff;",
  "&#x10FFFF;", "&#x110000;", "&#1114112;", "&#99999999999999999999999;", "&#x1F600;", "&#128512;",
  "&#00065;", "&#;", "&#x;", "&#xg;", "&#65", "&amp;#65;", "&#38;amp;", "a&#10;b", "&#xFFFE;",
  "&#x80;", "&#150;", "x &lt;y&gt; &#x26; z", "&quot;quoted&quot; &apos;s",
];
const entities = entityInputs.map(s => ({ s, unescaped: unescapeHtmlEntities(s) }));

const simPairs = [
  ["", ""], ["a", ""], ["", "a"], ["Hello World", "hello world"], ["Hello World", "Hello there World"],
  ["The Title - Site", "The Title"], ["The Title", "The Title - Site"], ["caf\u00E9 au lait", "cafe au lait"],
  ["a_b c", "a b c"], ["foo, bar; baz", "baz bar foo"], ["\u65E5\u672C\u8A9E", "\u65E5\u672C\u8A9E"], ["x", "y"],
  ["Kelvin \u212A", "kelvin k"], ["\u0130stanbul", "i stanbul"], ["one two three", "one one one four"],
  ["!!!", "word"], ["word", "..."], ["A B C D", "a b c d e f g h"],
];
const similarity = simPairs.map(([a, b]) => ({ a, b, similarity: textSimilarity(a, b) }));

// One case per line keeps diffs of the fixture readable.
const section = (name, rows) => `"${name}": [\n${rows.map(r => JSON.stringify(r)).join(",\n")}\n]`;
const sections = [section("text", text), section("entities", entities), section("similarity", similarity)];
process.stdout.write(`{\n${sections.join(",\n")}\n}\n`);
