#!/usr/bin/env node
// Golden traces of Readability.js on its own test pages. See scripts/traces/README.md.
//
//   node scripts/traces/trace.js [--input jsdomparser|lexbor] [--out DIR] [page ...]
//
// Zero npm dependencies: it only loads the vendored Readability.js, Readability-readerable.js
// and JSDOMParser.js from test/fixtures/readability_js/js.
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "../..");
const JS_DIR = path.join(ROOT, "test/fixtures/readability_js/js");
const PAGES_DIR = path.join(ROOT, "test/fixtures/readability_js/pages");
const URI = "http://fakehost/test/page.html";
const OPTIONS = { classesToPreserve: ["caption"] };
const FORMAT_VERSION = 1;

const Readability = require(path.join(JS_DIR, "Readability.js"));
const JSDOMParser = require(path.join(JS_DIR, "JSDOMParser.js"));
const isProbablyReaderable = require(path.join(JS_DIR, "Readability-readerable.js"));

// --- trees -------------------------------------------------------------------------------------

// [localName, [[name, value], ...], [children...]]; text nodes are plain strings.
function dump(node) {
  switch (node.nodeType) {
    case 3:
      return node.textContent;
    case 1:
      return [
        // --input lexbor keeps LazyHTML's tag case (SVG camelCase) unless _setNodeTag renamed it.
        node._lexborTag?.toLowerCase() === node.localName ? node._lexborTag : node.localName,
        node.attributes.map((a) => [a.name, a.value]),
        node.childNodes.map(dump),
      ];
    default:
      throw new Error("unexpected node type " + node.nodeType + " (" + node.nodeName + ")");
  }
}

// The document is dumped as the list of its child nodes (JSDOMParser keeps only <html>).
const dumpDoc = (doc) => doc.childNodes.map(dump);

// Node -> child-index path from the document (forward order, all child nodes counted).
function pathMap(doc) {
  const map = new Map();
  (function walk(nodes, prefix) {
    for (let i = 0; i < nodes.length; i++) {
      const p = prefix.concat(i);
      map.set(nodes[i], p);
      if (nodes[i].nodeType === 1) walk(nodes[i].childNodes, p);
    }
  })(doc.childNodes, []);
  return map;
}

function pathOf(doc, node) {
  const p = [];
  for (let n = node; n && n !== doc; n = n.parentNode) {
    const parent = n.parentNode;
    if (!parent) return null; // detached
    p.unshift(parent.childNodes.indexOf(n));
  }
  return p;
}

const num = (x) => ({ score: x, score_js: String(x) });

// --- readerable shim -----------------------------------------------------------------------------
// isProbablyReaderable needs querySelectorAll("p, pre, article"), querySelectorAll("div > br") and
// Element#matches("li p"). JSDOMParser has none of them; implement exactly those three.

function installSelectorShim(doc) {
  const ElementProto = Object.getPrototypeOf(doc.createElement("div"));
  if (!ElementProto.matches) {
    ElementProto.matches = function (selector) {
      if (selector !== "li p") throw new Error("shim: unsupported selector " + selector);
      if (this.localName !== "p") return false;
      for (let n = this.parentNode; n && n.nodeType === 1; n = n.parentNode) {
        if (n.localName === "li") return true;
      }
      return false;
    };
  }
  doc.querySelectorAll = function (selector) {
    const all = this.getElementsByTagName("*");
    if (selector === "p, pre, article") {
      return all.filter((e) => ["p", "pre", "article"].includes(e.localName));
    }
    if (selector === "div > br") {
      return all.filter((e) => e.localName === "br" && e.parentNode.localName === "div");
    }
    throw new Error("shim: unsupported selector " + selector);
  };
  return doc;
}

// --- input -------------------------------------------------------------------------------------

function parseJSDOMParser(source) {
  const parser = new JSDOMParser();
  const doc = parser.parse(source, URI);
  if (parser.errorState) throw new Error("JSDOMParser errors: " + parser.errorState);
  return doc;
}

// Builds a JSDOMParser Document from a dumped tree (e.g. LazyHTML's, exported by
// scripts/parser_parity.exs), mimicking what JSDOMParser.parse sets on the document.
function buildDoc(tree) {
  const doc = new JSDOMParser().parse("", URI);
  function build(t) {
    if (typeof t === "string") return doc.createTextNode(t);
    const [tag, attrs, children] = t;
    const el = doc.createElement(tag);
    // createElement strips a namespace prefix ("o:p" -> "p"); keep the tag as given.
    el.localName = tag.toLowerCase();
    el.tagName = tag.toUpperCase();
    el._lexborTag = tag;
    for (const [name, value] of attrs) el.setAttribute(name, value);
    for (const c of children) el.appendChild(build(c));
    if (el.localName === "title" && !doc.title) doc.title = el.textContent.trim();
    else if (el.localName === "head") doc.head = el;
    else if (el.localName === "body") doc.body = el;
    else if (el.localName === "html") doc.documentElement = el;
    return el;
  }
  for (const t of tree) doc.appendChild(build(t));
  return doc;
}

// --- the traced Readability ----------------------------------------------------------------------

const base = Readability.prototype;

// Inject hook calls into _grabArticle at anchor strings. Each anchor must occur exactly once.
function patchGrabArticle() {
  let src = base._grabArticle.toString();
  const inject = (anchor, where, code) => {
    const i = src.indexOf(anchor);
    if (i === -1 || src.indexOf(anchor, i + 1) !== -1) {
      throw new Error("_grabArticle anchor not found exactly once: " + JSON.stringify(anchor));
    }
    const at = where === "before" ? i : i + anchor.length;
    src = src.slice(0, at) + "\n" + code + "\n" + src.slice(at);
  };

  inject('this.log("Starting grabArticle loop");', "after", 'this.__hook("attempt_start", { page });');
  inject("var candidates = [];", "before", 'this.__hook("walk_done", { elementsToScore });');
  inject("var topCandidates = [];", "before", 'this.__hook("scored", { candidates });');
  inject("var neededToCreateTopCandidate = false;", "before", 'this.__hook("top_candidates", { candidates, topCandidates });');
  inject('var articleContent = doc.createElement("DIV");', "before",
    'this.__hook("top_candidate", { topCandidate, neededToCreateTopCandidate });');
  inject("parentOfTopCandidate = topCandidate.parentNode;\n      var siblings", "before",
    'this.__hook("parent_of_top_candidate", { parentOfTopCandidate: topCandidate.parentNode });');
  inject('this.log("Appending node:", sibling);', "after", 'this.__hook("append_sibling", { sibling });');
  inject("this._prepArticle(articleContent);", "before", 'this.__hook("pre_prep", { articleContent });');
  inject("this._prepArticle(articleContent);", "after", 'this.__hook("post_prep", { articleContent });');
  inject("var textLength = this._getInnerText(articleContent, true).length;", "after",
    'this.__hook("length_check", { articleContent, textLength });');
  inject("if (!this._attempts[0].textLength) {", "after", 'this.__hook("no_content", {});');
  inject("return articleContent;\n      }\n    }", "before", 'this.__hook("success", { articleContent });');

  const body = src.slice(src.indexOf("{") + 1, src.lastIndexOf("}"));
  // eslint-disable-next-line no-new-func
  return new Function("page", body);
}

const FLAG_NAMES = [
  [base.FLAG_STRIP_UNLIKELYS, "strip_unlikelys"],
  [base.FLAG_WEIGHT_CLASSES, "weight_classes"],
  [base.FLAG_CLEAN_CONDITIONALLY, "clean_conditionally"],
];

function Traced(doc, options) {
  Readability.call(this, doc, options);
  this.__t = { attempts: [] };
}
Traced.prototype = Object.create(base);
Traced.prototype.constructor = Traced;
Traced.prototype._grabArticle = patchGrabArticle();

const clone = (x) => (x === undefined ? null : JSON.parse(JSON.stringify(x)));

Object.assign(Traced.prototype, {
  _getJSONLD(doc) {
    const r = base._getJSONLD.call(this, doc);
    this.__t.json_ld = clone(r);
    return r;
  },
  _getArticleMetadata(jsonld) {
    const r = base._getArticleMetadata.call(this, jsonld);
    this.__t.metadata = clone(r); // parse() mutates metadata.excerpt later
    return r;
  },
  _prepDocument() {
    base._prepDocument.call(this);
    this.__t.prepped = dumpDoc(this._doc);
  },
  _postProcessContent(articleContent) {
    this.__t.before_post_process = dump(articleContent);
    base._postProcessContent.call(this, articleContent);
    this.__t.after_post_process = dump(articleContent);
  },

  __hook(name, v) {
    const t = this.__t;
    const doc = this._doc;
    const attempt = t.attempts[t.attempts.length - 1];
    switch (name) {
      case "attempt_start": {
        t.article_title = this._articleTitle;
        const start = JSON.stringify(dumpDoc(doc));
        const a = {
          number: t.attempts.length + 1,
          flags: this._flags,
          flag_names: FLAG_NAMES.filter(([f]) => this._flags & f).map(([, n]) => n),
        };
        // Attempt 1 starts from `prepped`. Later attempts start from page.innerHTML re-parsed by
        // JSDOMParser; record whether that round trip changed the tree.
        const prepped = (t.__prepped_json ||= JSON.stringify(t.prepped));
        a.start_equals_prepped = start === prepped;
        if (!a.start_equals_prepped) a.start = JSON.parse(start);
        t.attempts.push(a);
        this.__paths = null;
        break;
      }
      case "walk_done": {
        attempt.lang = this._articleLang ?? null;
        attempt.byline_after_walk = this._articleByline;
        attempt.post_walk = dumpDoc(doc);
        this.__paths = pathMap(doc);
        attempt.elements_to_score = v.elementsToScore.length;
        attempt.elements_to_score_paths = v.elementsToScore.map((n) => this.__path(n));
        break;
      }
      case "scored":
        // Raw scores at the end of the scoring loop, in insertion order.
        attempt.candidates = v.candidates.map((n) => ({
          path: this.__path(n),
          tag: n.localName,
          ...num(n.readability.contentScore),
        }));
        break;
      case "top_candidates":
        // After scaling by (1 - link density).
        v.candidates.forEach((n, i) => {
          const s = num(n.readability.contentScore);
          attempt.candidates[i].final_score = s.score;
          attempt.candidates[i].final_score_js = s.score_js;
        });
        attempt.top_candidates = v.topCandidates.map((n) => ({
          path: this.__path(n),
          tag: n.localName,
          ...num(n.readability.contentScore),
        }));
        break;
      case "top_candidate": {
        const n = v.topCandidate;
        attempt.top_candidate = {
          created: v.neededToCreateTopCandidate,
          // A created top candidate is a new <div> holding all of <body>'s old children.
          path: v.neededToCreateTopCandidate ? pathOf(doc, n) : this.__path(n),
          tag: n.localName,
          ...num(n.readability.contentScore),
        };
        attempt.appended_siblings = [];
        break;
      }
      case "parent_of_top_candidate":
        attempt.parent_of_top_candidate = this.__path(v.parentOfTopCandidate) ?? pathOf(doc, v.parentOfTopCandidate);
        break;
      case "append_sibling":
        attempt.appended_siblings.push({ path: this.__path(v.sibling), tag: v.sibling.localName });
        break;
      case "pre_prep":
        attempt.article_pre_prep = dump(v.articleContent);
        break;
      case "post_prep":
        attempt.article_post_prep = dump(v.articleContent);
        break;
      case "length_check":
        // articleContent now has the readability-page-1 wrapper.
        attempt.article = dump(v.articleContent);
        attempt.text_length = v.textLength;
        attempt.char_threshold = this._charThreshold;
        attempt.passed = v.textLength >= this._charThreshold;
        attempt.byline = this._articleByline;
        (this.__articles ||= new Map()).set(v.articleContent, attempt.number);
        break;
      case "no_content":
        t.result_attempt = null;
        break;
      case "success":
        t.result_attempt = this.__articles.get(v.articleContent);
        t.byline = this._articleByline;
        t.dir = this._articleDir;
        t.lang = this._articleLang ?? null;
        break;
      default:
        throw new Error("unknown hook " + name);
    }
  },

  __path(node) {
    const p = this.__paths.get(node);
    return p === undefined ? null : p;
  },
});

// --- upstream-style content comparison -----------------------------------------------------------
// Readability.js's test re-parses both sides (after js-beautify) and walks them in order, skipping
// whitespace-only text nodes, comparing localName/id/className, collapsed text and attribute counts.
// We can't run js-beautify, so text is also trimmed (as test/support/dom_compare.ex does).

function contentTokens(html) {
  const doc = new JSDOMParser().parse(html.trim(), URI);
  const out = [];
  (function walk(nodes) {
    for (const n of nodes) {
      if (n.nodeType === 3) {
        const text = n.textContent.replace(/\s+/g, " ").trim();
        if (text) out.push("#text(" + text + ")");
      } else if (n.nodeType === 1) {
        out.push(n.localName + (n.id ? "#" + n.id : "") + (n.className ? ".(" + n.className + ")" : "") + "@" + n.attributes.length);
        walk(n.childNodes);
      }
    }
  })(doc.childNodes);
  return out;
}

function compareContent(actual, expected) {
  const a = contentTokens(actual);
  const e = contentTokens(expected);
  for (let i = 0; i < Math.max(a.length, e.length); i++) {
    if (a[i] !== e[i]) return { index: i, actual: a[i] ?? null, expected: e[i] ?? null };
  }
  return null;
}

// --- driver --------------------------------------------------------------------------------------

function readPage(page) {
  const dir = path.join(PAGES_DIR, page);
  return {
    // Upstream's test runner trims the source.
    source: fs.readFileSync(path.join(dir, "source.html"), "utf8").trim(),
    expected: fs.readFileSync(path.join(dir, "expected.html"), "utf8").trim(),
    metadata: JSON.parse(fs.readFileSync(path.join(dir, "expected-metadata.json"), "utf8")),
  };
}

const METADATA_KEYS = ["title", "byline", "excerpt", "siteName", "dir", "lang", "publishedTime"];

function tracePage(page, opts) {
  const { source, expected, metadata } = readPage(page);
  let makeDoc;
  if (opts.input === "lexbor") {
    const file = path.join(opts.lexborDir, page + ".json");
    const tree = JSON.parse(fs.readFileSync(file, "utf8"));
    makeDoc = () => buildDoc(tree);
  } else {
    makeDoc = () => parseJSDOMParser(source);
  }

  // Timing on an uninstrumented run (best of 3).
  let parseMs = Infinity;
  let readabilityMs = Infinity;
  for (let i = 0; i < 3; i++) {
    const t0 = performance.now();
    const doc = makeDoc();
    const t1 = performance.now();
    new Readability(doc, OPTIONS).parse();
    const t2 = performance.now();
    parseMs = Math.min(parseMs, t1 - t0);
    readabilityMs = Math.min(readabilityMs, t2 - t1);
  }

  const doc = makeDoc();
  const input = dumpDoc(doc);
  const reader = new Traced(doc, OPTIONS);
  const result = reader.parse();
  const t = reader.__t;

  const readerable = isProbablyReaderable(installSelectorShim(makeDoc()));

  const trace = {
    format: FORMAT_VERSION,
    page,
    input_parser: opts.input,
    uri: URI,
    options: OPTIONS,
    timing_ms: { parse: +parseMs.toFixed(3), readability: +readabilityMs.toFixed(3) },
    input,
    json_ld: t.json_ld,
    metadata: t.metadata,
    article_title: t.article_title,
    prepped: t.prepped,
    attempts: t.attempts,
    result_attempt: t.result_attempt ?? null,
    article_byline: t.byline ?? null,
    article_dir: t.dir ?? null,
    article_lang: t.lang ?? null,
    before_post_process: t.before_post_process ?? null,
    after_post_process: t.after_post_process ?? null,
    // undefined -> null so every key is present in the JSON
    result: result && Object.fromEntries(Object.entries(result).map(([k, v]) => [k, v ?? null])),
    readerable,
  };

  // Sanity checks against the page's expectations.
  const problems = [];
  if (!result) {
    problems.push("parse() returned null");
  } else {
    for (const k of METADATA_KEYS) {
      if (k in metadata && (metadata[k] ?? null) !== (result[k] ?? null)) {
        problems.push(`${k}: got ${JSON.stringify(result[k])}, expected ${JSON.stringify(metadata[k])}`);
      }
    }
    // JSDOMParser can't fairly re-parse output built from a spec parser's tree (it leaves &nbsp;
    // etc. undecoded), so for --input lexbor the content check is done by parser_parity.exs.
    if (opts.input === "jsdomparser") {
      const diff = compareContent(result.content, expected);
      if (diff) problems.push("content: " + JSON.stringify(diff));
    }
  }
  if ("readerable" in metadata && metadata.readerable !== readerable) {
    problems.push(`readerable: got ${readerable}, expected ${metadata.readerable}`);
  }
  trace.checks = { ok: problems.length === 0, problems };
  return trace;
}

function main() {
  const args = process.argv.slice(2);
  const opts = { input: "jsdomparser", out: null, lexborDir: path.join(ROOT, "tmp/traces/lexbor-input") };
  const pages = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--input") opts.input = args[++i];
    else if (args[i] === "--out") opts.out = path.resolve(args[++i]);
    else if (args[i] === "--lexbor-dir") opts.lexborDir = path.resolve(args[++i]);
    else if (args[i].startsWith("--")) throw new Error("unknown option " + args[i]);
    else pages.push(args[i]);
  }
  if (!["jsdomparser", "lexbor"].includes(opts.input)) throw new Error("--input must be jsdomparser or lexbor");
  opts.out ||= path.join(ROOT, opts.input === "lexbor" ? "tmp/traces/lexbor" : "tmp/traces");
  fs.mkdirSync(opts.out, { recursive: true });

  const all = fs.readdirSync(PAGES_DIR).filter((d) => fs.statSync(path.join(PAGES_DIR, d)).isDirectory()).sort();
  const selected = pages.length ? pages : all;

  const started = performance.now();
  let bytes = 0;
  const failed = [];
  const hist = {};
  for (const page of selected) {
    let trace;
    try {
      trace = tracePage(page, opts);
    } catch (e) {
      console.error(`${page}: CRASH ${e.stack}`);
      failed.push(page);
      continue;
    }
    const json = JSON.stringify(trace);
    fs.writeFileSync(path.join(opts.out, page + ".json"), json);
    bytes += Buffer.byteLength(json);
    hist[trace.attempts.length] = (hist[trace.attempts.length] || 0) + 1;
    if (!trace.checks.ok) {
      failed.push(page);
      console.error(`${page}: ${trace.checks.problems.join("; ").slice(0, 400)}`);
    }
  }
  const secs = ((performance.now() - started) / 1000).toFixed(1);
  console.log(
    `${selected.length} pages traced (input: ${opts.input}) into ${path.relative(ROOT, opts.out)}: ` +
      `${(bytes / 1e6).toFixed(1)} MB in ${secs} s; attempts histogram ${JSON.stringify(hist)}; ` +
      `${selected.length - failed.length} match expectations, ${failed.length} don't`
  );
  process.exitCode = failed.length && opts.input === "jsdomparser" ? 1 : 0;
}

main();
