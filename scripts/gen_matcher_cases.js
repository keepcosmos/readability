// Generates test/fixtures/matcher_cases.json: results of Readability.js's own regexes (taken
// from the vendored source, not retyped where they are reachable) over strings from the
// Readability.js test pages plus hand-made edge cases.
//
//   node scripts/gen_matcher_cases.js
//
// Strings are read with the vendored JSDOMParser, the DOM the oracle runs on. No npm dependencies.
"use strict";
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const jsDir = path.join(root, "test/fixtures/readability_js/js");
const pagesDir = path.join(root, "test/fixtures/readability_js/pages");
const JSDOMParser = require(path.join(jsDir, "JSDOMParser.js"));
const Readability = require(path.join(jsDir, "Readability.js"));
const R = Readability.prototype.REGEXPS;

// Inline regexes of Readability.js (copied verbatim from the functions that use them).
const imageExt = /\.(jpg|jpeg|png|webp)/i;
const lazySrcset = /\.(jpg|jpeg|png|webp)\s+\d/;
const lazySrc = /^\s*\S+\.(jpg|jpeg|png|webp)\S*\s*$/;
const titleSeparators = /\|\-–—\\\/>»/.source;
const titleSep = new RegExp(`\\s[${titleSeparators}]\\s`);
const titleHier = /\s[\\\/>»]\s/;
const propertyPattern =
  /\s*(article|dc|dcterm|og|twitter)\s*:\s*(author|creator|description|published_time|title|site_name)\s*/gi;
const namePattern =
  /^\s*(?:(dc|dcterm|og|twitter|parsely|weibo:(article|webpage))\s*[-\.:]\s*)?(author|creator|pub-date|description|title|site_name)\s*$/i;
const schemaDotOrgRegex = /^https?\:\/\/schema\.org\/?$/;
const cdata = /^\s*<!\[CDATA\[|\]\]>\s*$/g;
const sentenceEnd = /\.( |$)/;

// Check that the copies above still match the vendored source.
const src = fs.readFileSync(path.join(jsDir, "Readability.js"), "utf8");
for (const re of [imageExt, lazySrcset, lazySrc, titleHier, propertyPattern, namePattern, schemaDotOrgRegex, cdata, sentenceEnd]) {
  const lit = "/" + re.source + "/" + re.flags;
  if (!src.includes(lit)) throw new Error(`regex not found in Readability.js: ${lit}`);
}
if (!src.includes("/\\|\\-–—\\\\\\/>»/.source")) throw new Error("title separators changed");

const MAX = 120; // longer values are truncated (the expected result is computed on the truncated value)
const cut = s => (s.length > MAX ? s.slice(0, MAX) : s);

const classIdStrings = new Set();
const pairs = new Map();
const imageAttrs = new Set();
const videoValues = new Set();
const shortTexts = new Set();
const titles = new Set();
const metaValues = new Set();
const jsonldTypes = new Set();
const contexts = new Set();
const cdataValues = new Set();
const hashValues = new Set();
const srcsets = new Set();

const videoHint = /dailymotion|youtube|vimeo|qq|bilibili|archive|wikimedia|twitch/i;

function collectTypes(v) {
  if (Array.isArray(v)) return v.forEach(collectTypes);
  if (v && typeof v === "object") {
    for (const [k, x] of Object.entries(v)) {
      if (k === "@type" && typeof x === "string") jsonldTypes.add(x);
      else if (k === "@context") {
        if (typeof x === "string") contexts.add(x);
        else if (x && typeof x["@vocab"] === "string") contexts.add(x["@vocab"]);
      } else collectTypes(x);
    }
  }
}

let pageCount = 0;
for (const page of fs.readdirSync(pagesDir).sort()) {
  const file = path.join(pagesDir, page, "source.html");
  if (!fs.existsSync(file)) continue;
  pageCount++;
  const doc = new JSDOMParser().parse(fs.readFileSync(file, "utf8").trim(), "http://fakehost/test/page.html");
  titles.add(doc.title);

  for (const el of doc.getElementsByTagName("*")) {
    const className = el.className;
    const id = el.id;
    classIdStrings.add(className);
    classIdStrings.add(id);
    // with one side empty, the pair tests reduce to the single-string tests above
    if (className && id) pairs.set(JSON.stringify([className, id]), [className, id]);

    const tag = el.localName;
    for (const attr of el.attributes) {
      const v = attr.value;
      if (["img", "picture", "figure", "source"].includes(tag)) imageAttrs.add(cut(v));
      if (["iframe", "embed", "object", "param", "video", "source"].includes(tag)) videoValues.add(cut(v));
      else if (attr.name === "href" && videoHint.test(v)) videoValues.add(cut(v));
      if (attr.name === "href" && v.startsWith("#")) hashValues.add(cut(v));
      if (attr.name === "srcset") srcsets.add(cut(v));
      if (tag === "meta" && (attr.name === "property" || attr.name === "name")) metaValues.add(v);
    }

    const text = el.textContent.trim().replace(R.normalize, " ");
    // adWords / loadingWords cannot match more than 13 code units
    if (text.length <= 13 && /^[\p{L}.…]+$/u.test(text)) shortTexts.add(text);

    if (tag === "script" && el.getAttribute("type") === "application/ld+json") {
      const content = el.textContent;
      cdataValues.add(content.length > 2 * MAX ? content.slice(0, MAX) + content.slice(-MAX) : content);
      try {
        collectTypes(JSON.parse(content.replace(cdata, "")));
      } catch {}
    }
  }
}

// Hand-made edge cases.
const EDGE_CLASS_ID = [
  "", " ", "hid", "HID", "Hid", " hid", "hid ", " hid ", "a hid", "hid b", "a hid b", "xhid", "hidx", "a hidx",
  "ahid b", "a\thid", "hid\tb", "a hid", "hidden", "HIDDEN", "-ad-", "-AD-", "x-ad-y", "ad", "ads", "ad-break",
  "AD-BREAK", "share", "Share", "SHARE", "sharedaddy", "shareDaddy", "sharedaddyx", "sharedaddy_x", "x_sharedaddy",
  "share_x", "x_share", "x_share_y", "reshare", "shares", "share-1", "share1", "1share", "-share-", "share.x",
  "_share_", "sharé", "ésharé", "éshare", "shareé", "ſhare", "ſidebar", "sidebar", "SideBar", "commENT",
  "comment-list", "and", "AND", "brand", "candidate", "main-header", "header", "footer main", "article", "articles",
  "entry", "hentry", "h-entry", "H-Entry", "byline", "ByLine", "author", "p-author", "writtenby", "dateline",
  "lazy", "Lazy-Load", "LAZYLOAD", "lazy x", "lazİ", "laZy", "post", "page", "pagination", "pager",
  "pagination-pager", "text", "context", "blog", "story", "history", "Komment", "cömment", "com-",
  "com", "media", "metadata", "tags", "widget", "scroll", "promo", "masthead", "outbrain", "shopping", "contact",
  "gdpr", "combx", "banner", "breadcrumbs", "community", "cover-wrap", "disqus", "extra", "legends", "menu",
  "related", "remark", "replies", "rss", "shoutbox", "skyscraper", "social", "sponsor", "supplemental",
  "agegate", "popup", "yom-remote", "ai2html", "mathjax", "shadow", "column", "body", "content", "İhid",
];
for (const s of EDGE_CLASS_ID) classIdStrings.add(s);
for (const a of EDGE_CLASS_ID.slice(0, 60)) for (const b of ["", "hid", "main", "share", "sidebar"]) {
  pairs.set(JSON.stringify([a, b]), [a, b]);
  pairs.set(JSON.stringify([b, a]), [b, a]);
  classIdStrings.add(a + " " + b);
  classIdStrings.add(b + " " + a);
}

const EDGE_IMAGE = [
  "", "a.jpg", "A.JPG", "a.Jpg", ".jpg", "..jpg", "x.jpeg", "x.png", "x.webp", "x.gif", "x.jpg?w=1", " a.jpg ",
  " a.jpg　", "a b.jpg", "a.jpg b", "a.jpg 1x", "a.jpg  2x", "a.jpg\t3w", "a.jpg 1x", "a.jpgx 1x",
  "a.jpg x", "a.JPG 1x", "a.jpeg 100w, b.png 200w", "a.webp,b.webp", "a.png\n", "\na.png", "é.png", "a.pngé",
  "data:image/gif;base64,R0lGODlhAQABAIAAAP", "DATA:image/png;BASE64,iVBOR", "data: image/png ; base64 , iVBOR",
  "data:image/svg+xml;base64,PHN2Zz4=", "data:image/png;base64", "data:;base64,AAAA", "data:image/png,abc",
  "data:image/png;charset=utf-8;base64,AAAA", "data: image/png; base64 ,x", "data:image/png;base64x,",
  " data:image/png;base64,AAAA", "data:image/pngé;base64,AAAA", "data:a,b;base64,x",
];
for (const s of EDGE_IMAGE) imageAttrs.add(s);

const EDGE_VIDEO = [
  "//www.youtube.com/embed/x", "https://youtube.com/embed/x", "https://www.YouTube.com/x", "//youtube-nocookie.com/x",
  "//player.vimeo.com/video/1", "//playerxvimeo.com/", "//v.qq.com/x", "//live.bilibili.com/1", "//livexbilibili.com/1",
  "//live\nbilibili.com/1", "//live\rbilibili.com/1", "//live bilibili.com/1", "//liveébilibili.com/1",
  "//live\u{1F600}bilibili.com/1", "//bilibili.com", "//archive.org/x", "//upload.wikimedia.org/x",
  "//player.twitch.tv/x", "//www.dailymotion.com/x", "http://example.com/youtube.com", "youtube.com", "//wwwyoutube.com",
];
for (const s of EDGE_VIDEO) videoValues.add(s);

const EDGE_TEXT = [
  "ad", "Ad", "AD", "ads", "advertising", "Advertisement", "ADVERTISEMENT", "advert", "pub", "publicité", "PUBLICITÉ",
  "publicite", "werb", "werbung", "Werbung", "广告", "Реклама", "РЕКЛАМА", "реклама", "anuncio", "Anuncio", "loading",
  "Loading...", "LOADING…", "loading..", "正在加载", "正在加载…", "Загрузка", "загрузка...", "chargement", "Chargement…",
  "cargando", "CARGANDO...", " ad", "ad ", "ad\n", "advertiſing", "Kad", "loading...\n",
];
for (const s of EDGE_TEXT) shortTexts.add(s);

const EDGE_TITLES = [
  "", "A - B", "A | B", "A – B", "A — B", "A \\ B", "A / B", "A > B", "A » B", "A-B", "A -B", "A - B",
  "A\t|\tB", "A　»　B", "One two three four - Site", "Site - One two three four", "a - b - c - d e f",
  "Short: title here with words", "x » y » z", "no separators here at all", "A - B\n", "-A - B", "|", " | ",
  "A / B", "A\u0085-\u0085B", "A﻿-﻿B", "été - café — naïve",
];
for (const s of EDGE_TITLES) titles.add(s);

const EDGE_META = [
  "og:title", "OG:Title", "og : title", " og:title ", "og:title og:description", "twitter:description", "dc:creator",
  "dcterm:creator", "dcterms:creator", "article:published_time", "article:author", "og:site_name", "og:titles",
  "xog:title", "og: title", "og:﻿title", "og:\u0085title", "author", "Author", " author ", "dc.creator",
  "DC.Title", "dc-title", "dcterm:title", "parsely-pub-date", "weibo:article:title", "weibo:webpage:description",
  "weibo:other:title", "twitter:title", "og title", "og: title\n", "title\n", "sailthru.author", "description",
  "og:description", "og:image", "pub-date", "site_name", "og-site_name", "og.site_name", "og:site-name",
];
for (const s of EDGE_META) metaValues.add(s);

const EDGE_TYPES = [
  "Article", "NewsArticle", "article", "ArticleX", "XArticle", "BlogPosting", "Report", "Reportage", "APIReference",
  "XAPIReference", "APIReferenceX", "WebPage", "Person", "", "LiveBlogPosting", "SocialMediaPosting\n",
  "APIReference\n", "TechArticle", "Thing",
];
for (const s of EDGE_TYPES) jsonldTypes.add(s);
for (const s of ["http://schema.org", "https://schema.org/", "http://schema.org//", "https://SCHEMA.org", "http://schema.org/\n", "schema.org", ""]) contexts.add(s);
for (const s of ["", "{}", "<![CDATA[{}]]>", "  <![CDATA[ {} ]]>  ", "\n<![CDATA[{}]]>\n", "{}]]>", "<![CDATA[{}", "x<![CDATA[{}]]>x", "<![CDATA[]]>", " <![CDATA[{}]]>　", "]]> ]]>  "]) cdataValues.add(s);
for (const s of ["#", "#a", "#\n", "#\r", "# ", "# ", "#\u0085", "# ", "#é", "a#b", "", "##"]) hashValues.add(s);
const sentenceValues = ["", ".", "a.", "a. b", "a.b", "a .", "a.\n", "a. b", ". ", "...", "a,b"];
for (const s of [
  "a.jpg 1x, b.jpg 2x", "a.jpg,b.jpg", "a b", "a,b c", "a.jpg 1.5x", "a.jpg 1xw", " a.jpg 1x ,b.jpg 2x ", "a.jpg 1x",
  "a.jpg 100w,\nb.jpg 200w", "", ",", "a.jpg 1x,", "é.jpg 1x", "a.jpg 1x, b.jpg",
]) srcsets.add(s);

// Results.
const bit = (b, v) => (v ? b : 0);
const strings = [...classIdStrings].sort().map(s => [
  s,
  bit(1, R.unlikelyCandidates.test(s)) | bit(2, R.okMaybeItsACandidate.test(s)) | bit(4, R.positive.test(s)) |
    bit(8, R.negative.test(s)) | bit(16, R.byline.test(s)) | bit(32, R.shareElements.test(s)) |
    bit(64, s.toLowerCase().includes("lazy")),
]);

function classWeight(className, id) {
  let weight = 0;
  if (typeof className === "string" && className !== "") {
    if (R.negative.test(className)) weight -= 25;
    if (R.positive.test(className)) weight += 25;
  }
  if (typeof id === "string" && id !== "") {
    if (R.negative.test(id)) weight -= 25;
    if (R.positive.test(id)) weight += 25;
  }
  return weight;
}

const pairCases = [...pairs.values()].sort().map(([c, i]) => {
  const m = c + " " + i;
  const unlikely = R.unlikelyCandidates.test(m) && !R.okMaybeItsACandidate.test(m);
  return [c, i, bit(1, unlikely) | bit(2, R.byline.test(m)) | bit(4, R.shareElements.test(m)), classWeight(c, i)];
});

const imageCases = [...imageAttrs].sort().map(v => {
  const parts = R.b64DataUrl.exec(v);
  return [
    v,
    bit(1, imageExt.test(v)) | bit(2, lazySrcset.test(v)) | bit(4, lazySrc.test(v)),
    parts ? [parts[0], parts[1]] : null,
  ];
});

const titleCases = [...titles].sort().map(t => {
  const all = Array.from(t.matchAll(new RegExp(`\\s[${titleSeparators}]\\s`, "gi")));
  return [
    t,
    bit(1, titleSep.test(t)) | bit(2, titleHier.test(t)),
    all.length ? t.substring(0, all.pop().index) : null,
    t.replace(new RegExp(`^[^${titleSeparators}]*[${titleSeparators}]`, "gi"), ""),
    t.replace(new RegExp(`\\s[${titleSeparators}]\\s`, "g"), ""),
  ];
});

const metaCases = [...metaValues].sort().map(v => {
  const matches = v.match(propertyPattern);
  return [
    v,
    matches ? matches[0].toLowerCase().replace(/\s/g, "") : null,
    namePattern.test(v) ? v.toLowerCase().replace(/\s/g, "").replace(/\./g, ":") : null,
  ];
});

const out = {
  generator: "scripts/gen_matcher_cases.js",
  node: process.version,
  // bits: 1 unlikelyCandidates, 2 okMaybeItsACandidate, 4 positive, 8 negative, 16 byline,
  //       32 shareElements, 64 toLowerCase().includes("lazy")
  strings,
  // [className, id, bits, classWeight]; bits: 1 unlikely && !okMaybe, 2 byline, 4 shareElements
  pairs: pairCases,
  // [value, bits, b64DataUrl [match, mime] | null]; bits: 1 image extension /i, 2 lazy srcset, 3 lazy src
  image_attrs: imageCases,
  videos: [...videoValues].sort().map(v => [v, R.videos.test(v)]),
  ad_loading: [...shortTexts].sort().map(t => [t, R.adWords.test(t) || R.loadingWords.test(t)]),
  // [title, bits (1 separator, 2 hierarchical), cut before last separator | null, first part removed, separators removed]
  titles: titleCases,
  // [value, property key | null, name key | null]
  meta: metaCases,
  jsonld_types: [...jsonldTypes].sort().map(t => [t, !!t.match(R.jsonLdArticleTypes)]),
  schema_org: [...contexts].sort().map(s => [s, schemaDotOrgRegex.test(s)]),
  cdata: [...cdataValues].sort().map(s => [s, s.replace(cdata, "")]),
  hash_url: [...hashValues].sort().map(s => [s, R.hashUrl.test(s)]),
  sentence_end: sentenceValues.map(s => [s, s.search(sentenceEnd) !== -1]),
  srcset: [...srcsets].sort().map(s => [s, s.replace(R.srcsetUrl, (_, p1, p2, p3) => "[" + p1 + "]" + (p2 || "") + p3)]),
};

const outFile = path.join(root, "test/fixtures/matcher_cases.json");
fs.writeFileSync(outFile, JSON.stringify(out) + "\n");
const counts = Object.entries(out)
  .filter(([, v]) => Array.isArray(v))
  .map(([k, v]) => `${k} ${v.length}`)
  .join(", ");
console.log(`${pageCount} pages: ${counts}; ${fs.statSync(outFile).size} bytes -> ${path.relative(root, outFile)}`);
