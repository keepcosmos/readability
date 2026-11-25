#!/usr/bin/env node
// The `readability-js` target of benchmark.exs: Readability.js (the vendored copy the port
// follows) on its own JSDOMParser, timed the way the Elixir targets are. Zero npm dependencies.
//
//   node benchmarks/readability_js.js OUT.json QUICK NAME=INPUT.html... -- CORPUS.html...
//
// Each call parses the HTML with JSDOMParser and runs `parse()`, as upstream's tests do (the
// document is consumed by `parse()`, so it can't be reused). Writes the rows and the corpus pass
// as JSON in the shape benchmark.exs reads.
"use strict";

const fs = require("fs");
const path = require("path");

const JS_DIR = path.resolve(__dirname, "../test/fixtures/readability_js/js");
const Readability = require(path.join(JS_DIR, "Readability.js"));
const JSDOMParser = require(path.join(JS_DIR, "JSDOMParser.js"));
const URI = "http://fakehost/test/page.html";

const [out, quick, ...rest] = process.argv.slice(2);
const sep = rest.indexOf("--");
const inputs = rest.slice(0, sep);
const corpus = rest.slice(sep + 1);
// The same budget as Benchee's warmup and run time in benchmark.exs.
const [warmupNs, timeNs] = quick === "1" ? [0.5e9, 1e9] : [2e9, 5e9];

function job(html) {
  const doc = new JSDOMParser().parse(html, URI);
  return new Readability(doc).parse();
}

function runFor(html, budgetNs, samples) {
  const start = process.hrtime.bigint();
  while (Number(process.hrtime.bigint() - start) < budgetNs) {
    const t0 = process.hrtime.bigint();
    job(html);
    if (samples) samples.push(Number(process.hrtime.bigint() - t0));
  }
}

function stats(samples) {
  samples.sort((a, b) => a - b);
  const at = (q) => samples[Math.min(samples.length - 1, Math.floor(q * samples.length))];
  const mean = samples.reduce((a, b) => a + b, 0) / samples.length;
  const sd = Math.sqrt(samples.reduce((a, b) => a + (b - mean) ** 2, 0) / samples.length);
  return {
    ips: 1e9 / mean,
    median_ns: at(0.5),
    p99_ns: at(0.99),
    deviation_pct: (100 * sd) / mean,
    sample_size: samples.length,
    memory_bytes: null,
    reductions: null,
  };
}

const rows = inputs.map((arg) => {
  const eq = arg.indexOf("=");
  const html = fs.readFileSync(arg.slice(eq + 1), "utf8");
  const row = { input: arg.slice(0, eq) };
  try {
    runFor(html, warmupNs, null);
    const samples = [];
    runFor(html, timeNs, samples);
    const s = stats(samples);
    console.log(`  bench ${row.input}: median ${(s.median_ns / 1e6).toFixed(2)} ms`);
    return { ...row, ...s, status: "ok" };
  } catch (e) {
    console.log(`  bench ${row.input}: error ${e}`);
    return { ...row, status: "error", error: String(e).slice(0, 300) };
  }
});

const htmls = corpus.map((file) => fs.readFileSync(file, "utf8"));
const tryJob = (html) => {
  try {
    job(html);
    return true;
  } catch (e) {
    return false;
  }
};
htmls.slice(0, 5).forEach(tryJob);
const t0 = process.hrtime.bigint();
const errors = htmls.filter((html) => !tryJob(html)).length;
const totalMs = Math.floor(Number(process.hrtime.bigint() - t0) / 1e6);
console.log(`  bench corpus: ${totalMs} ms over ${htmls.length} pages, ${errors} errors`);

const commit = fs.readFileSync(path.resolve(__dirname, "../test/fixtures/readability_js/COMMIT"), "utf8").trim();
const versions = { "Readability.js": commit.slice(0, 7), node: process.versions.node };
fs.writeFileSync(out, JSON.stringify({ versions, rows, corpus: { pages: htmls.length, total_ms: totalMs, errors } }));
