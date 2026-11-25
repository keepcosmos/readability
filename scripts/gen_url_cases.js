// Generates test/fixtures/url_cases.json: expected WHATWG URL results from Node's `URL`
// for every URL-ish attribute value in the Readability.js test pages, plus edge cases.
//
//   node scripts/gen_url_cases.js
//
// Attribute values are read with the vendored JSDOMParser, the DOM the oracle runs on.
// No npm dependencies.
"use strict";
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const jsDir = path.join(root, "test/fixtures/readability_js/js");
const pagesDir = path.join(root, "test/fixtures/readability_js/pages");
const JSDOMParser = require(path.join(jsDir, "JSDOMParser.js"));
const Readability = require(path.join(jsDir, "Readability.js"));

const DOC_URI = "http://fakehost/test/page.html";
const srcsetUrl = Readability.prototype.REGEXPS.srcsetUrl;

function resolve(input, base) {
  try {
    return base === null ? new URL(input).href : new URL(input, base).href;
  } catch {
    return null;
  }
}

// Edge cases plausible in HTML attributes, partly taken from the WHATWG URL test data. Hosts that
// need IDNA or IPv4 parsing are left out: lib/readability/url.ex keeps them as written.
const EDGE_INPUTS = [
  "", " ", "#", "#frag", "#frag ment", "?", "?q=1", "?q=a b", "?q=\"'<>`", "/", "//", "///", "////x",
  "//example.com", "//EXAMPLE.com:80/a", "//user:pass@example.com:8080/p?q#f", "//@example.com/",
  "/a/b/../c", "/a/./b/", "a/..", "a/../..", "../../../../x", "./", ".", "..", "./a/../b",
  "a/%2e%2E/b", "a/%2e/b", "a/.%2e/b", "%2e", "%2e%2e/x", "a/b/..", "a/b/.",
  "\\a\\b", "\\\\host\\path", "/\\host", "http:\\\\host\\a\\b", "http:/\\host", "http:host/a", "http:/a",
  "http:", "https:", "http:?q", "http:#f", "http://", "http:///", "http:// ", "http://a b/", "http://[::1]/",
  "http://[1:0::]/", "http://[0:0:0:0:0:0:0:1]/", "http://[::ffff:1.2.3.4]/", "http://[",
  "http://[::ffff:1.+2.3.4]/", "http://[::ffff:1.2.3.+4]/", "http://[::ffff:1.2.3.-0]/", "http://[+1::]/",
  "http://[ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255]/", "http://[0000:0000:0000:0000:0000:0000:0000:00000]/",
  "http://1.2.3.4/", "http://example.com.:80/",
  "http://EXAMPLE.COM/A?B#C", "HTTP://Example.Com/", "http://example.com:/", "http://example.com:0080/",
  "http://example.com:65535/", "http://example.com:65536/", "http://example.com:8a/", "https://ex.com:443/",
  "ws://ex.com:80/", "wss://ex.com:443/", "ftp://ex.com:21/", "ftp://ex.com:22/",
  "http://user@ex.com/", "http://user:@ex.com/", "http://:pass@ex.com/", "http://us er:p@ss@ex.com/",
  "http://ex.com/a b", "http://ex.com/a\tb\nc\rd", " \t http://ex.com/ \n", "\u0000http://ex.com/\u001f",
  "http://ex.com/\u00e9", "http://ex.com/?\u00e9", "http://ex.com/#\u00e9", "http://ex.com/%zz", "http://ex.com/%41",
  "http://ex.com/{}|^`", "http://ex.com/?{}|^`'", "http://ex.com/#{}|^`'\"<> ", "http://ex.com/a?b#c#d",
  "http://ex.com/\ud83d\ude00", "http://ex.com/a%20b", "http://ex.com/<>\"", "http://ex.com/a/./b/../c",
  "http://ex.com/a/%2e%2e/c", "http://ex.com/..", "http://ex.com/../..", "http://ex.com/a/..", "http://ex.com/.",
  "http://ex.com/a/.", "http://ex.com/%2e", "http://ex.com//a//b", "http://ex.com\\a\\b", "http://ex.com?q",
  "http://ex.com#f", "http://ex%41mple.com/", "http://ex%2Fmple.com/", "http://ex<mple.com/", "http://ex^mple.com/",
  "http://ex%00mple.com/", "http://exa mple.com/", "http://xn--mnchen-3ya.de/",
  "https://www.youtube.com/embed/abc?rel=0&amp;x=1", "mailto:someone@example.com", "mailto:a b@ex.com",
  "tel:+1 555 1234", "javascript:void(0)", "javascript:alert('x y')", "JavaScript:void(0)", "data:image/gif;base64,R0lGOD",
  "data:,a b", "about:blank", "urn:isbn:0451450523", "news:comp.lang", "foo:bar baz", "foo://host/a b?c d#e f",
  "foo://HOST/", "foo://host:99/", "foo:///x", "foo:/a/../b", "foo:/.//p", "foo://", "foo://h/..//p", "sc:\\../",
  "file:///C:/a/b", "file:///etc/passwd", "file://host/share", "file://localhost/etc", "file:/a", "file:a",
  "file:\\\\host\\a", "file://LOCALHOST/x", "file:///a/../..", "file:?q", "file:#f", "file://h/c:/x/../..",
  "1http://ex.com", "+http://ex.com", "a+b.c-d:x", "h\ttp://ex.com", "ht\ntp://ex.com", "http\r://ex.com",
  "http:/\t/ex.com", "%68ttp://ex.com", "\u3000http://ex.com/", "http://ex.com/\u3000", "\u00a0/a",
  "a\u00a0b", "x:\u00e9", "?\u00e9", "#\u00e9 \"<>`", "/%", "/a%", "/%G0", "a?b#c?d", "?#", "#?", "a#", "a?",
  "http://a/b/c/d;p?q", "g:h", "g", "./g", "g/", "/g", "//g", "?y", "g?y", "#s", "g#s", "g?y#s", ";x", "g;x",
  "g;x?y#s", "", ".", "./", "..", "../", "../g", "../..", "../../", "../../g", "../../../g", "/./g", "/../g",
  "g.", ".g", "g..", "..g", "./../g", "./g/.", "g/./h", "g/../h", "g;x=1/./y", "g;x=1/../y", "g?y/./x",
  "g?y/../x", "g#s/./x", "g#s/../x", "http:g",
];

const EDGE_BASES = [
  DOC_URI, "http://a/b/c/d;p?q", "https://EX.com:443/dir/file?x#y", "http://ex.com", "http://ex.com/",
  "foo://host/a/b", "foo:/a/b", "foo:opaque", "about:blank", "file:///C:/dir/file", "file://host/a/b",
  "http://user:pw@ex.com:8080/a/b?q#f", "data:text/html,abc", "mailto:x@ex.com",
];

// Collected values: [input, base] pairs to resolve, and strings for `new URL(str)` (_isUrl, base parsing),
// kept apart for page-derived values and hand-made edge cases.
const pagePairs = new Map();
const edgePairs = new Map();
const pageSingles = new Set();
const edgeSingles = new Set();
let pairs = pagePairs;
let singles = pageSingles;
const addPair = (input, base) => pairs.set(JSON.stringify([input, base]), [input, base]);

const pages = fs.readdirSync(pagesDir).sort();
let pageCount = 0;
for (const page of pages) {
  const file = path.join(pagesDir, page, "source.html");
  if (!fs.existsSync(file)) continue;
  pageCount++;
  const src = fs.readFileSync(file, "utf8").trim();
  const doc = new JSDOMParser().parse(src, DOC_URI);
  const baseURI = doc.baseURI;
  const bases = baseURI === DOC_URI ? [DOC_URI] : [DOC_URI, baseURI];

  for (const base of doc.getElementsByTagName("base")) {
    const href = base.getAttribute("href");
    if (href !== null && href !== undefined) {
      addPair(href, DOC_URI);
      singles.add(href);
    }
  }
  singles.add(baseURI);

  const values = [];
  for (const el of doc.getElementsByTagName("*")) {
    for (const name of ["href", "src", "poster"]) {
      const v = el.getAttribute(name);
      if (v) values.push(v);
    }
    const srcset = el.getAttribute("srcset");
    if (srcset) {
      srcset.replace(srcsetUrl, (_, p1) => values.push(p1));
    }
    if (el.tagName === "META") {
      const prop = (el.getAttribute("property") || "") + " " + (el.getAttribute("name") || "");
      const content = el.getAttribute("content");
      if (content && /author/i.test(prop)) singles.add(content.trim());
    }
  }
  for (const v of values) for (const b of bases) addPair(v, b);
}

pairs = edgePairs;
singles = edgeSingles;
for (const input of EDGE_INPUTS) {
  singles.add(input);
  for (const base of EDGE_BASES) addPair(input, base);
}
for (const base of EDGE_BASES) singles.add(base);

// Resolve cases grouped by base: {base: [[input, href]]}. href is null where `new URL` throws and
// true where it equals the input (keeps the fixture small).
function resolveCases(pairMap) {
  const byBase = {};
  const sorted = [...pairMap.values()].sort((a, b) => (a[1] + "\u0000" + a[0] < b[1] + "\u0000" + b[0] ? -1 : 1));
  for (const [input, base] of sorted) {
    const href = resolve(input, base);
    (byBase[base] ||= []).push([input, href === input ? true : href]);
  }
  return byBase;
}
const parseCases = set => [...set].sort().map(s => [s, resolve(s, null)]);

const out = {
  generator: "scripts/gen_url_cases.js",
  node: process.version,
  pages: { resolve: resolveCases(pagePairs), parse: parseCases(pageSingles) },
  edge: { resolve: resolveCases(edgePairs), parse: parseCases(edgeSingles) },
};
const count = o => Object.values(o.resolve).reduce((n, cs) => n + cs.length, 0);
const outFile = path.join(root, "test/fixtures/url_cases.json");
fs.writeFileSync(outFile, JSON.stringify(out, null, 0) + "\n");
console.log(
  `${pageCount} pages: ${count(out.pages)} resolve + ${out.pages.parse.length} parse cases; ` +
    `edge: ${count(out.edge)} resolve + ${out.edge.parse.length} parse cases; ` +
    `${fs.statSync(outFile).size} bytes -> ${path.relative(root, outFile)}`
);
