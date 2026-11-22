# Readability.js test pages

`pages/` is the test suite of [Mozilla Readability.js](https://github.com/mozilla/readability),
vendored at the commit in `COMMIT` by [`scripts/sync_readability_js.sh`](../../../scripts/sync_readability_js.sh).
It's licensed under the Apache License 2.0 (`LICENSE.md`), like this library.

Each page has `source.html` (the input, as served from `http://fakehost/test/page.html`),
`expected.html` (Readability.js's article content) and `expected-metadata.json`.

`test/readability_js_test.exs` checks every page against them, and
`MIX_ENV=test mix run scripts/conformance.exs` prints a summary. `known_failures.txt`
lists the checks that fail today; it may only shrink.
