# Readability

[![CI](https://github.com/keepcosmos/readability/actions/workflows/elixir.yml/badge.svg)](https://github.com/keepcosmos/readability/actions/workflows/elixir.yml)
[![Module Version](https://img.shields.io/hexpm/v/readability.svg)](https://hex.pm/packages/readability)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/readability/)
[![Total Download](https://img.shields.io/hexpm/dt/readability.svg)](https://hex.pm/packages/readability)
[![License](https://img.shields.io/hexpm/l/readability.svg)](https://github.com/keepcosmos/readability/blob/master/LICENSE.md)

Readability extracts the main content of a web page: the article without navigation, ads and
other page chrome, plus its title, byline, excerpt and other metadata.

It's a port of Mozilla's [Readability.js](https://github.com/mozilla/readability), the library
behind Firefox's Reader View, on top of the [LazyHTML](https://hex.pm/packages/lazy_html) parser
(Lexbor). It passes every check of Readability.js's own test suite (130 pages, comparing the
extracted content and metadata), which runs as part of this library's tests.

## Installation

```elixir
def deps do
  [
    {:readability, "~> 1.0.0-rc.1"}
  ]
end
```

This is a release candidate; once 1.0.0 is out, use `{:readability, "~> 1.0"}`.

Readability requires Elixir 1.17 or newer and OTP 27 or newer.

## Usage

```elixir
{:ok, article} = Readability.article(html, url: "https://example.com/blog/post")

article.title          #=> "A blog post"
article.byline         #=> "Jane Doe"
article.content        #=> "<div id=\"readability-page-1\" class=\"page\"><p>The first paragraph..."
article.text_content   #=> "The first paragraph..."
```

`Readability.article/2` returns `{:ok, %Readability.Article{}}`, `{:error, :not_readable}` when
there's no article, `{:error, :too_many_elements}` when the page has more elements than
`:max_elems_to_parse`, or `{:error, :too_deep}` when its elements nest deeper than `:max_depth`.
`Readability.article!/2` returns the article or raises `Readability.Error`.

An article has these fields, the same as the result of Readability.js's `parse()`:

| field | |
|---|---|
| `title` | the article title |
| `byline` | the author line, or `nil` |
| `content` | the article as HTML |
| `text_content` | the article's text |
| `length` | the length of `text_content` (UTF-16 code units, like JS) |
| `excerpt` | the page's description, or the article's first paragraph |
| `site_name` | the name of the site, or `nil` |
| `published_time` | the publication time from the page's metadata, as found (not parsed), or `nil` |
| `dir`, `lang` | the text direction and language, or `nil` |

`Readability.readerable?/2` is a fast check (Readability.js's `isProbablyReaderable`) of whether
a page probably has an article, to decide whether to run `article/2` at all.

Both take the HTML as a string or as a document parsed with `LazyHTML.from_document/2`. A string
is parsed with a depth limit (`:max_depth`, 1000 by default). Parse it yourself to call both
without parsing twice, or to set all of LazyHTML's limits (`:max_depth`, `:max_memory`,
`:max_attributes`, `:timeout`) for untrusted input; a parsed document is used as is.

### Output is not sanitized

Like Readability.js, Readability removes scripts and page chrome, but it is not a sanitizer:
`content` keeps attributes such as `onclick` or `onerror`, and links can point anywhere. Sanitize
it (for example with [html_sanitize_ex](https://hex.pm/packages/html_sanitize_ex)) before
rendering content from untrusted pages.

### Options

- `:url` - the page's URL. Relative links and image sources in `content` are made absolute
  against it and the page's `<base href>`. Without it, they stay as they are, unless the page
  has an absolute `<base href>`.
- `:char_threshold` - when the extracted text is shorter, extraction is retried with looser
  rules; if every attempt is short, the longest one is returned.
- `:max_depth` (1000) - give up on HTML whose elements nest deeper than this (parsing time is
  quadratic in the depth); `:infinity` for no limit.
- `:spawn` (false) - do the work in a short-lived linked process, which keeps garbage
  collection out of the way and releases the memory at once (about a fifth faster on typical
  pages). HTML up to 2 MB gets a heap preallocated at two words per byte (16 MB at most per
  call); larger HTML starts with the default heap. Results, exceptions and exits are passed on
  to the caller, and the caller's `:max_heap_size` applies to the process, but its `$callers`
  and Logger metadata don't.
- `:char_threshold` (500), `:nb_top_candidates` (5), `:max_elems_to_parse` (0, no limit),
  `:classes_to_preserve` ([]), `:keep_classes` (false), `:disable_json_ld` (false),
  `:allowed_video_regex`, `:link_density_modifier` (0.0): Readability.js's options. See the
  [documentation](https://hexdocs.pm/readability/Readability.html#module-options).

### Fetching pages

Readability doesn't fetch pages. Use the HTTP client you already have, for example
[Req](https://hex.pm/packages/req):

```elixir
url = "https://example.com/blog/post"
html = Req.get!(url).body
{:ok, article} = Readability.article(html, url: url)
```

The HTML must be UTF-8, as it is on almost every page today. Readability.js never sees bytes (the
browser decodes the page first), but here a page in another encoding would come out as
replacement characters. So when most of a page's non-ASCII bytes aren't UTF-8 and it declares
another encoding in a `<meta>`, `article/2` returns `{:error, {:unsupported_charset, label}}`
(with the encoding's label, such as `"shift_jis"`) and `readerable?/2` returns `false`. Decode
such pages to UTF-8 first, with an encoding library such as
[encoding_rs](https://hex.pm/packages/encoding_rs).

## Performance

Readability works on LazyHTML's tree with precomputed text statistics instead of a DOM, and avoids
regular expressions on hot paths. See [benchmarks/RESULTS.md](https://github.com/keepcosmos/readability/blob/master/benchmarks/RESULTS.md) for numbers
and `benchmarks/benchmark.exs` to run them.

## Credits

- [Mozilla Readability.js](https://github.com/mozilla/readability) (Apache-2.0), of which this is
  a port, and whose test pages are the test suite.
- Readability was created by [Jaehyun Shin](https://github.com/keepcosmos).

## License

Copyright (c) 2016 Jaehyun Shin and contributors. Readability.js is Copyright (c) 2010 Arc90 Inc.

Licensed under the Apache License, Version 2.0. See [LICENSE.md](LICENSE.md) and [NOTICE](https://github.com/keepcosmos/readability/blob/master/NOTICE).
