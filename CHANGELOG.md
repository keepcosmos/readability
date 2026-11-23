# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0-rc.1 - Unreleased

A rewrite: Readability is now a port of Mozilla's
[Readability.js](https://github.com/mozilla/readability) on top of
[LazyHTML](https://hex.pm/packages/lazy_html). The API is new; see the migration table below
([#71](https://github.com/keepcosmos/readability/issues/71)).

### Breaking

- No HTTP client: `Readability.summarize/2` and the `httpoison` dependency are gone. Fetch pages
  with the client you already use and pass the HTML to `Readability.article/2`
  ([#64](https://github.com/keepcosmos/readability/issues/64)).
- `Readability.article/2` returns `{:ok, %Readability.Article{}}` or
  `{:error, :not_readable | :too_many_elements | :too_deep}` instead of a Floki tree.
- Removed `title/1`, `authors/1`, `published_at/1`, `readable_html/1`, `readable_text/1`,
  `raw_html/1`, `parse/1`, `regexes/1`, `mime/1`, `is_response_markup/1`, `default_options/0` and
  `Readability.Summary`. Their results are fields of `Readability.Article`.
- Floki is replaced by LazyHTML (Lexbor, a spec-compliant HTML parser). `floki` is no longer a
  dependency, and there's no parser to choose
  ([#68](https://github.com/keepcosmos/readability/issues/68) no longer applies).
- New options, named after Readability.js's (`:url`, `:char_threshold`, `:nb_top_candidates`,
  `:max_elems_to_parse`, `:classes_to_preserve`, `:keep_classes`, `:disable_json_ld`,
  `:allowed_video_regex`, `:link_density_modifier`), validated with NimbleOptions: unknown or
  invalid options raise. The 0.x options are gone.
- `byline` is a string (Readability.js's byline), not a list of authors, and `published_time` is
  the string found in the page's metadata, not a parsed `DateTime`.
- Requires OTP 27 or newer.

### Added

- Passes every check of Readability.js's test suite on all 130 of its pages (content as a
  normalized DOM, attributes, title, byline, excerpt, site name, and direction, language and
  published time where the page has them), checked in CI by a conformance suite built on those
  pages
  ([#61](https://github.com/keepcosmos/readability/issues/61),
  [#63](https://github.com/keepcosmos/readability/issues/63)).
- `Readability.article!/2`, raising `Readability.Error`.
- `Readability.readerable?/2`, a port of Readability.js's `isProbablyReaderable`.
- Article fields: `excerpt`, `site_name`, `dir`, `lang`, `length`; metadata from JSON-LD and
  `<meta>` tags.
- Relative links and image sources are made absolute with the `:url` option.
- Both functions accept a `%LazyHTML{}` document, so a page can be parsed once (with LazyHTML's
  limits, for untrusted input) for both.
- HTML nested deeper than the `:max_depth` option (1000 levels by default) is rejected while
  parsing, with `{:error, :too_deep}` from `Readability.article/2` and `false` from
  `Readability.readerable?/2`: parsing time grows quadratically with the depth.
- `Readability.article/2` works in a short-lived process (option `:spawn`, on by default) whose
  heap is sized for pages up to 2 MB (16 MB at most), which keeps garbage collection out of the
  way.
- Benchmarks (`benchmarks/benchmark.exs`) against 0.x and the cost of parsing alone.

### Fixed

- `content` is serialized per the HTML standard, so text is escaped
  ([#62](https://github.com/keepcosmos/readability/issues/62)).
- Options are validated in one place ([#57](https://github.com/keepcosmos/readability/issues/57)
  no longer applies: `summarize` is gone).

### Differences from Readability.js

- Relative URLs are resolved with a subset of the WHATWG URL Standard: hosts with non-ASCII
  characters are kept as written (lower-cased only for ASCII letters) instead of being converted
  to Punycode, and numeric hosts such as `0x7f.1` are not rewritten as IPv4 addresses (or
  rejected when out of range). Links on such hosts can differ from Readability.js's output.

### Migrating from 0.x

| 0.x | 1.0 |
|---|---|
| `Readability.summarize(url)` | fetch the page, then `Readability.article(html, url: url)` |
| `Readability.readable_html(Readability.article(html))` | `{:ok, a} = Readability.article(html)`, then `a.content` |
| `Readability.readable_text(Readability.article(html))` | `a.text_content` |
| `Readability.title(html)` | `a.title` |
| `Readability.authors(html)` | `a.byline` (a string) |
| `Readability.published_at(html)` | `a.published_time` (a string) |
| `summary.article_html` / `summary.article_text` | `a.content` / `a.text_content` |
| options `:page_url` | `:url` |
| other 0.x options (`:retry_length`, `:min_text_length`, `:weight_classes`, ...) | none; see `Readability` for the new ones |
| `Floki` operations on the result | parse `a.content` with `LazyHTML.from_fragment/1` (or Floki) |

## [0.13.0] - 2026-11-22

### Breaking

- Require Elixir 1.17 or newer (previously 1.10).
- Allow `httpoison ~> 3.0` (hackney 4.x), which fixes several hackney security
  advisories ([#70](https://github.com/keepcosmos/readability/pull/70)).
  httpoison 3 requires OTP 27+. Hex does not take your OTP version into account
  when resolving dependencies, so on OTP 26 or older pin it in your own project:
  `{:httpoison, "~> 2.0"}`.

- Require `floki ~> 0.30`. The previous `~> 0.24` floor did not compile, since
  `Floki.parse_fragment!/1` does not exist in older versions.

### Added

- `published_at` field in the summary returned by `Readability.summarize/2`, and `Readability.published_at/1`
  ([#58](https://github.com/keepcosmos/readability/pull/58)).

### Fixed

- `Readability.title/1` and `Readability.published_at/1` now accept raw HTML
  strings ([#60](https://github.com/keepcosmos/readability/pull/60)).
- Incorrect node format for the doctype when Floki uses the `html5ever` parser
  ([#66](https://github.com/keepcosmos/readability/pull/66)).
- Regex escape errors on Elixir 1.18 ([#69](https://github.com/keepcosmos/readability/pull/69)).

### Changed

- The Hex package no longer bundles locally generated `doc/` files.
- Updated development dependencies and CI (Elixir 1.17–1.20, OTP 27–29).

## [0.12.1] - 2024-01-11

### Changed

- The default title selector is now `h1`.

## [0.12.0] - 2023-12-13

### Changed

- Up to 100x faster on large pages by caching queries ([#53](https://github.com/keepcosmos/readability/pull/53)).
- Allow `httpoison ~> 1.8 or ~> 2.0`.

### Fixed

- `<font>` tags were incorrectly replaced with `<1span>` during normalization.
- Deprecation warnings from newer Floki versions.

For older releases, see [Hex](https://hex.pm/packages/readability/versions) and the [commit history](https://github.com/keepcosmos/readability/commits/master).

[0.13.0]: https://github.com/keepcosmos/readability/compare/v0.12.1...v0.13.0
[0.12.1]: https://github.com/keepcosmos/readability/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/keepcosmos/readability/releases/tag/v0.12.0
