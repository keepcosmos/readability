# Golden traces of Readability.js

Per-stage snapshots of Readability.js running on its own test pages, so every stage of the port
(metadata, prep, grab walk/score/select, `_prepArticle`, post-processing) can be tested in
isolation against the real thing. Design: `docs/1.0-design.md` §7, Stage 0.

## Generating

```sh
scripts/traces.sh            # all 130 pages, ~12 s, ~170 MB in tmp/traces (git-ignored)
scripts/traces.sh 001 cnn    # some pages
```

It needs Node (tested on 24) and Mix. Node only loads the vendored
`test/fixtures/readability_js/js/{Readability.js,Readability-readerable.js,JSDOMParser.js}`, no
npm packages. The steps:

| step | writes | what |
|---|---|---|
| `node scripts/traces/trace.js` | `tmp/traces/<page>.json` (74 MB) | Readability.js on **JSDOMParser**, exactly as upstream's test runs it |
| `mix run scripts/parser_parity.exs --export-only` | `tmp/traces/lexbor-input/<page>.json` (26 MB) | LazyHTML's tree of each page, converted like `Traces.from_lazy/1` |
| `node scripts/traces/trace.js --input lexbor` | `tmp/traces/lexbor/<page>.json` (74 MB) | Readability.js on **LazyHTML's tree** (built into JSDOMParser's DOM classes) |

Each run checks Readability.js's own result against the page's expectations and prints the pages
that don't match (all 130 match in both modes): every key of `expected-metadata.json` (title,
byline, excerpt, siteName, dir, lang, publishedTime, readerable; `null` and missing are equal),
and, for JSDOMParser input, the content the way upstream compares it (re-parse both sides, skip
whitespace-only text, compare tag/id/class/attribute count and whitespace-collapsed text). We
can't run js-beautify, so text is also trimmed, like `test/support/dom_compare.ex`. The content
check of the lexbor run is done by `parser_parity.exs` with `DOMCompare`, because JSDOMParser
can't fairly re-parse output built from a spec parser's tree (it leaves `&nbsp;` undecoded).

Timing (best of 3 uninstrumented runs, recorded per page in `timing_ms`): JSDOMParser parse
168 ms and `parse()` 503 ms summed over all pages.

## Which traces to test against

**Use the `:lexbor` traces as the exact oracle for stage tests.** Their input is the tree our port
sees, so trees, paths, candidate sets and float scores are directly comparable. The
`:jsdomparser` traces are what upstream literally computes; they differ on many pages for
parser reasons only (see below): 105 of 130 pages have identical candidates and scores in both
modes, 25 don't (mostly text lengths, because JSDOMParser leaves `&nbsp;` & co. undecoded), and
`textContent` differs on 23.

What the lexbor run does not change is the DOM *API* semantics: those are still JSDOMParser's,
which is what the design tells us to follow (`_setNodeTag` renames in place, `style` is a
`;`/`:` split, retries re-parse `innerHTML` with JSDOMParser).

Readability.js on LazyHTML's tree passes **all 130 pages** under our conformance checks
(`DOMCompare` `:content` and `:attributes`, all metadata fields, `readerable`). So no page is
out of reach because of the parser: a faithful port can match `expected.html` everywhere.

## Using traces from Elixir

`Readability.Test.Traces` (`test/support/traces.ex`):

```elixir
trace = Traces.load("cnn", :lexbor)                   # raw JSON map, string keys, null -> nil
Traces.tree(trace, "prepped")                         # [node]  in the design §2.1 shape
Traces.tree(trace, "before_post_process")             # node
[attempt | _] = Traces.attempts(trace)                # trees converted, paths reversed, scores floats
Traces.diff_trees(actual, attempt["post_walk"])       # :ok | {:diff, "at html[0] > body[2] > …: …"}
```

Nodes are `{tag, attrs, children, nil}` with attributes in DOM order, text nodes are binaries.
`diff_trees/2` compares exactly (tags, attribute lists in order, text byte for byte, child
counts), ignores the 4th slot and also accepts 3-tuples.

Tests that use traces must be tagged `:traces`. `test/test_helper.exs` excludes the tag unless
both `tmp/traces` and `tmp/traces/lexbor` exist, so CI (which has no traces) skips them.
`test/traces_test.exs` checks the loader and the path convention on every page.

## JSON format (`format: 1`)

Trees are nested arrays `[tag, [[name, value], ...], [children...]]`, text nodes are strings.
Never HTML: these trees don't survive a re-parse. Attributes are in DOM order. JSDOMParser keeps
no other node types (comments and `<!…>`/`<?…>` are discarded, CDATA becomes text); the dumper
throws on anything else. Tags are JSDOMParser's `localName` (lower case, namespace prefix
stripped: `g:plusone` is `plusone`); in lexbor traces they are LazyHTML's tags (SVG camelCase)
unless `_setNodeTag` renamed the element.

A **document tree** is the list of the document's child nodes. JSDOMParser keeps only `<html>`
there, so it's `[["html", …]]`. An **article tree** is the single `articleContent` element.

**Paths** are child-index paths from the document, root first: `[0, 3, 2]` is
`document.childNodes[0].childNodes[3].childNodes[2]`. Indexes count all child nodes, text
included (design §2.3). Paths in an attempt refer to that attempt's `post_walk` tree.
`Traces.attempts/1` reverses them to the design's `[i_n, …, i_0]` form.

**Scores** are JS doubles. `JSON.stringify` writes the shortest round-tripping form and
`:json` decodes it exactly, so `score` is exact; `score_js` is `String(score)` for eyeballing.
Integral scores come out as JSON integers; `Traces.attempts/1` turns them into floats.

| key | content |
|---|---|
| `page`, `input_parser`, `uri`, `options`, `format` | what was run |
| `timing_ms` | `{parse, readability}`, uninstrumented, best of 3 |
| `input` | document tree right after parsing |
| `json_ld` | `_getJSONLD(doc)` result |
| `metadata` | `_getArticleMetadata(jsonLd)` result, copied before `parse()` adds `excerpt` |
| `article_title` | `_articleTitle` when `_grabArticle` starts |
| `prepped` | document tree after `_unwrapNoscriptImages`, `_removeScripts`, `_prepDocument` (what `_grabArticle` starts from) |
| `attempts` | one entry per pass of `_grabArticle`'s loop, below |
| `result_attempt` | number of the attempt whose article was returned (`null` if none) |
| `article_byline`, `article_dir`, `article_lang` | `_articleByline`, `_articleDir`, `_articleLang` when `_grabArticle` returns |
| `before_post_process`, `after_post_process` | article tree around `_postProcessContent` |
| `result` | `parse()`'s return value, `undefined` written as `null` |
| `readerable` | `isProbablyReaderable` on a fresh parse (JSDOMParser lacks selectors; `trace.js` shims exactly the three it uses) |
| `checks` | `{ok, problems}` from the checks above |

Per attempt:

| key | content |
|---|---|
| `number`, `flags`, `flag_names` | 1-based attempt number, `_flags` bitmask and names |
| `start_equals_prepped`, `start` | whether the document tree at the start of the attempt equals `prepped`; `start` is only present when it doesn't (see quirks) |
| `lang`, `byline_after_walk` | `_articleLang` and `_articleByline` after the node-prepping walk |
| `post_walk` | document tree after the walk: the tree scoring runs on |
| `elements_to_score`, `elements_to_score_paths` | count and paths of `elementsToScore`, in push order |
| `candidates` | every node that got `readability` initialized, in insertion order: `{path, tag, score, score_js}` at the end of the scoring loop, plus `final_score(_js)` after scaling by `1 - linkDensity` |
| `top_candidates` | `topCandidates` (`{path, tag, score}`), best first |
| `top_candidate` | the top candidate after refinement: `{created, path, tag, score}`. `created` means no usable candidate: a new `<div>` holding all of `<body>`'s children, whose `path` is in the tree after that move |
| `parent_of_top_candidate` | its path |
| `appended_siblings` | siblings appended to `articleContent`, in order (`{path, tag}`; the tag before any `_setNodeTag` to `div`) |
| `article_pre_prep`, `article_post_prep` | `articleContent` before and after `_prepArticle` |
| `article` | `articleContent` at the length check, i.e. with the `readability-page-1` wrapper |
| `text_length`, `char_threshold`, `passed` | the length check |
| `byline` | `_articleByline` at the length check |

## How `trace.js` instruments Readability.js

`Traced` is a subclass of `Readability` (prototype chain, nothing global is patched). It
overrides `_getJSONLD`, `_getArticleMetadata`, `_prepDocument` and `_postProcessContent` to
snapshot around the originals, and replaces `_grabArticle` with a copy of its source with hook
calls injected at anchor strings (`inject(...)` in `patchGrabArticle`). Every anchor must occur
exactly once, otherwise the script throws, so a Readability.js update that moves code fails
loudly instead of tracing the wrong place. A node-to-path map of the post-walk tree is built
when the walk ends; later lookups use it, so paths stay valid while the sibling loop moves
nodes.

## Parser parity

```sh
MIX_ENV=test mix run scripts/parser_parity.exs [--verbose] [page ...]
```

It compares `LazyHTML.from_document(source) |> LazyHTML.to_tree()` (comments dropped,
`<template>` childless, design §4.2) with the `input` tree of the JSDOMParser trace, then checks
both modes' Readability.js results with `DOMCompare`. Both parsers get the source trimmed with
JS `trim()`, like upstream's test runner.

Result: **no page parses identically.** Each page is counted at the loosest normalization it
needed (cumulative, applied to both trees):

| class | pages | what differs |
|---|---:|---|
| `html_whitespace` | 0 | whitespace-only text directly under `<html>` |
| `case` | 1 | tag / attribute-name case |
| `whitespace` | 35 | any whitespace-only text node |
| `entities` | 13 | named character references |
| `scripts` | 45 | content of `<script>`/`<style>` |
| `structure` | 36 | still different |

The 130 pages all differ at the first level already: JSDOMParser keeps whitespace text before
`<head>` and after `<body>` under `<html>`; Lexbor drops the former and appends the latter to
`<body>`'s last text node (so `<body>`'s trailing text differs on most pages). These are the
differences, all real parser behaviour (none is a conversion artifact):

- **Whitespace placement** (all pages): see above; also inside tables and wherever elements get
  moved. Harmless to the algorithm (it skips or trims whitespace-only text), but it shifts every
  index, so JSDOMParser-trace paths (`<body>` is `[0, 3]`) never equal ours (`[0, 2]`).
- **Named character references** (13 + many in `structure`/`scripts`): JSDOMParser decodes only
  `&lt; &gt; &amp; &quot; &apos;` and numeric references; `&nbsp;`, `&mdash;` etc. stay literal
  text. Text lengths, comma counts and thus scores differ. This is the main reason to test
  against lexbor traces.
- **Double decoding** (`005-unescape-html-entities`, `ehow-2`, `lazy-image-2`,
  `lifehacker-*`, `msn`, `nytimes-2`, `wikipedia-2`): JSDOMParser decodes `&amp;` first and then
  numeric references in the result, so `&amp;#39;` becomes `'`. Lexbor gives `&#39;`. Mostly in
  `<meta content>`; `_unescapeHtmlEntities` makes the metadata come out equal anyway.
- **Raw text elements** (`scripts` class, `buzzfeed-1` `<noembed>`): JSDOMParser parses
  `<script>`, `<style>`, `<noembed>` content as markup and keeps
  `<![CDATA[` sections as separate text nodes. Scripts and styles are removed before the walk;
  JSON-LD survives because Readability strips a CDATA wrapper itself.
- **Head content moved to `<body>`** (`bbc-1`, `breitbart`, `citylab-1`, `cnet`, `cnn`,
  `guardian-1`, `medicalnewstoday`, `nytimes-1`, `spiceworks`, `yahoo-3`): a spec parser ends
  `<head>` at the first element that doesn't belong there (an `<iframe>`, a `<div>`, non-trivial
  `<noscript>` content with scripting off) and puts the rest in `<body>`. Metadata still reads
  the whole document; the walk now also visits those nodes (all invisible or contentless here).
- **Content after `</body>`** (`bug-1255978`, `cnn`, `wikia`, `wikipedia-4`): JSDOMParser keeps
  it under `<html>`, the spec appends it to `<body>` (`mathjax`: trailing whitespace merged into
  body text that isn't whitespace-only).
- **Missing `<head>`** (`ol`): synthesized by Lexbor, absent in JSDOMParser.
- **Tree construction fix-ups** (`wikipedia` implied `<tbody>`, `wordpress` `<p>` implicitly
  closed by `<div>`, `heise` nested `<a>`, `iab-1` `</input>` end tag): JSDOMParser has no
  implied tags and no void-element knowledge beyond `/>`.
- **Attribute tokenizing** (`clean-links`, `medium-2`, `salon-1`, `webmd-2`, `mozilla-2`):
  JSDOMParser reads an attribute name up to the next `=`, so valueless attributes merge with the
  next one (`itemscope itemtype="…"` is one attribute) and can swallow markup (`selected>english
  </option><option lang="…"` in `mozilla-2`). Attribute names keep their source case.
- **Namespace prefixes** (`blogger` `g:plusone`, `youth` `wb:follow-button`): JSDOMParser strips
  them from `localName`; Lexbor keeps `g:plusone`.
- **`<template>`** (`article-author-tag`): childless by design (§4.2), JSDOMParser keeps its
  content as children.

Implications: none of these blocks conformance (Readability.js on LazyHTML's tree passes all 130
pages), and we should not mimic any of them. Two things the port must do on its side:

- **Strip a leading BOM.** `la-nacion` and `remove-aria-hidden` start with U+FEFF. A spec
  decoder strips it before tokenizing, `LazyHTML.from_document/1` on a string doesn't, and the
  BOM then becomes body text that pulls all of `<head>`'s content into `<body>`. Upstream's
  `trim()` removes it (U+FEFF is JS whitespace). `JSSuite.load/1` passes the source untrimmed.
- Trimming the rest of the source only changes `<body>`'s trailing whitespace text.

## Quirks the traces exposed

- **Retries don't restart from `prepped`.** `_grabArticle` resets only `<body>`, via
  `page.innerHTML = pageCacheHtml`, i.e. a serialize/re-parse round trip. In all 31 later
  attempts (both modes) the start tree is exactly: `<body>` as in `prepped` with **adjacent text
  nodes merged**, and everything outside `<body>` as the **previous attempt's walk left it**
  (e.g. `cnn`'s hidden `<iframe>` after `</body>` stays removed). Ten attempts on seven pages
  (`aclu`, `cnn`, `firefox-nightly-blog`, `hukumusume`, `lifehacker-*`, `medicalnewstoday`) start from a tree
  different from `prepped`; `start` holds it. The merge matters for `childNodes`-based checks
  and DIV→P whitespace trimming, so the design's "retry on the same prepared tree" needs a text
  merge of `<body>` to be exact.
- **`isPaging` is always true.** `parse()` calls `_grabArticle()` without an argument, and
  `undefined !== null`, so `articleContent` always gets `id="readability-content"`. It's not
  visible in `content` (that's `innerHTML`), but it is in the article trees.
