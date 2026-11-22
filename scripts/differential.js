#!/usr/bin/env node
// Runs Readability.js on LazyHTML trees for scripts/differential.exs (see there).
//
//   node scripts/differential.js IN.json OUT.json
//
// IN is a JSON array of {id, tree, url}, where `tree` is a document tree in the trace format
// (scripts/traces/README.md). OUT is a JSON array of {id, result, readerable, error, ms}, `result`
// being parse()'s return value (null for none) with undefined written as null.
// Zero npm dependencies: only the vendored Readability.js, Readability-readerable.js and JSDOMParser.js.
"use strict";

const fs = require("fs");
const path = require("path");

const JS_DIR = path.join(__dirname, "../test/fixtures/readability_js/js");
const Readability = require(path.join(JS_DIR, "Readability.js"));
const JSDOMParser = require(path.join(JS_DIR, "JSDOMParser.js"));
const isProbablyReaderable = require(path.join(JS_DIR, "Readability-readerable.js"));

// The same as buildDoc in scripts/traces/trace.js.
function buildDoc(tree, uri) {
  const doc = new JSDOMParser().parse("", uri);
  function build(t) {
    if (typeof t === "string") return doc.createTextNode(t);
    const [tag, attrs, children] = t;
    const el = doc.createElement(tag);
    el.localName = tag.toLowerCase();
    el.tagName = tag.toUpperCase();
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

// The same as installSelectorShim in scripts/traces/trace.js.
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
    if (selector === "p, pre, article") return all.filter((e) => ["p", "pre", "article"].includes(e.localName));
    if (selector === "div > br") return all.filter((e) => e.localName === "br" && e.parentNode.localName === "div");
    throw new Error("shim: unsupported selector " + selector);
  };
  return doc;
}

const [input, output] = process.argv.slice(2);
const cases = JSON.parse(fs.readFileSync(input, "utf8"));
const out = cases.map(({ id, tree, url }) => {
  const uri = url || "http://fakehost/test/page.html";
  const entry = { id, result: null, readerable: null, error: null, ms: null };
  try {
    entry.readerable = isProbablyReaderable(installSelectorShim(buildDoc(tree, uri)));
  } catch (e) {
    entry.error = "readerable: " + String(e && e.stack).slice(0, 300);
  }
  try {
    const t0 = performance.now();
    const result = new Readability(buildDoc(tree, uri)).parse();
    entry.ms = performance.now() - t0;
    entry.result = result && Object.fromEntries(Object.entries(result).map(([k, v]) => [k, v ?? null]));
  } catch (e) {
    entry.error = String(e && e.stack).slice(0, 300);
  }
  return entry;
});
fs.writeFileSync(output, JSON.stringify(out));
