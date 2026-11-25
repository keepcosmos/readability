defmodule Readability do
  @moduledoc """
  Extracts the main content of a web page: a port of Mozilla's
  [Readability.js](https://github.com/mozilla/readability), the library behind Firefox's Reader
  View, on top of [LazyHTML](https://hexdocs.pm/lazy_html).

      {:ok, article} = Readability.article(html, url: "https://example.com/post")
      article.title
      article.content       #=> "<div id=\\"readability-page-1\\" class=\\"page\\">…</div>"
      article.text_content

  See `Readability.Article` for the fields. Fetching the page is up to you: the README has an
  [example with Req](readme.html#fetching-pages).

  `content` is not sanitized: it keeps attributes such as `onclick` or `onerror`, and links can
  point anywhere. Sanitize it before rendering content from untrusted pages.

  ## Options

  #{Readability.Options.docs()}
  """

  alias Readability.{
    Article,
    Charset,
    Clean,
    DOM,
    Grab,
    Metadata,
    Options,
    PostProcess,
    Prep,
    Readerable,
    Text,
    URL,
    Worker
  }

  alias Readability.DOM.Serializer

  @typedoc "An HTML document, as a string or parsed with `LazyHTML.from_document/2`."
  @type input :: String.t() | LazyHTML.t()

  @typedoc """
  Why there's no article:

    * `:not_readable` - nothing that looks like an article was found (Readability.js returns `null`);
    * `:too_many_elements` - the document has more elements than `:max_elems_to_parse`
      (Readability.js throws);
    * `:too_deep` - the document's elements nest deeper than `:max_depth`;
    * `{:unsupported_charset, label}` - the document isn't valid UTF-8 and declares another
      encoding (`label`, lowercased, as in `<meta charset="shift_jis">`): decode it to UTF-8 first.
  """
  @type reason :: :not_readable | :too_many_elements | :too_deep | {:unsupported_charset, String.t()}

  @doc ~S"""
  Extracts the article from `html`, like Readability.js's `parse()`.

  `html` is a binary (a leading UTF-8 byte order mark is ignored) or a `%LazyHTML{}` parsed with
  `LazyHTML.from_document/2`. A binary is parsed with the `:max_depth` option as LazyHTML's depth
  limit. A `%LazyHTML{}` is used as is: parse it yourself to choose LazyHTML's limits
  (`:max_depth`, `:max_memory`, `:timeout`, ...) for untrusted input (it raises when one is
  exceeded), or to parse once for both `readerable?/2` and `article/2`.

  The HTML must be UTF-8 (a browser decodes it before Readability.js sees it). Malformed UTF-8
  becomes U+FFFD, as a decoder makes it, unless the document declares another encoding in a
  `<meta>` and most of its non-ASCII bytes aren't UTF-8: then the result is
  `{:error, {:unsupported_charset, label}}`. Decode such a page to UTF-8 first, using the
  encoding the HTTP `Content-Type` header or that `<meta>` names.

  Options are listed in the [module documentation](#module-options). Invalid options raise
  `NimbleOptions.ValidationError`.

      iex> text = String.duplicate("Some text here. ", 40)
      iex> {:ok, article} = Readability.article("<html><body><article><p>#{text}</p></article></body></html>")
      iex> article.length
      640

      iex> Readability.article("<html><body></body></html>")
      {:error, :not_readable}

  If you parse the HTML yourself, strip a leading byte order mark first: LazyHTML keeps it as
  text, which moves everything in the `<head>` into the `<body>`. Readability drops that U+FEFF,
  but can't move the elements back.
  """
  @spec article(input(), keyword()) :: {:ok, Article.t()} | {:error, reason()}
  def article(html, opts \\ []) do
    opts = Options.validate!(opts)
    if opts.spawn, do: Worker.run(fn -> run(html, opts) end, html), else: run(html, opts)
  end

  defp run(html, opts) do
    with {:ok, lazy, utf8} <- parse(html, opts.max_depth),
         {:ok, tree} <- valid_tree(LazyHTML.to_tree(lazy), lazy, utf8) do
      doc = DOM.from_lazy(tree)
      max = opts.max_elems_to_parse
      count = if max > 0, do: count_elements(doc, 0), else: 0

      # `parse()` checks the count before doing anything else
      if max > 0 and count > max,
        do: {:error, :too_many_elements},
        else: extract(doc, %{element_count: count}, opts)
    end
  end

  defp extract(doc, ctx, opts) do
    doc = Prep.unwrap_noscript_images(doc)
    json_ld = if opts.disable_json_ld, do: %{}, else: Metadata.json_ld(doc)
    doc = Prep.prep_document(doc)
    metadata = Metadata.extract(doc, json_ld)

    ctx = Map.merge(ctx, %{article_title: metadata.title, metadata_byline: metadata.byline})

    with {:ok, grabbed} <- Grab.run(doc, ctx, opts, &Clean.prep_article(&1, &2, opts)) do
      base_uri = URL.base_uri(opts.url, grabbed.base_href)
      article = PostProcess.run(grabbed.article, opts.url, base_uri, opts)
      {:ok, build(article, metadata, grabbed)}
    end
  end

  @doc """
  Like `article/2`, but returns the article or raises `Readability.Error`.
  """
  @spec article!(input(), keyword()) :: Article.t()
  def article!(html, opts \\ []) do
    case article(html, opts) do
      {:ok, article} -> article
      {:error, reason} -> raise Readability.Error, reason: reason
    end
  end

  @doc """
  Guesses whether `article/2` would find an article in `html`, much faster than running it.
  A port of Readability.js's `isProbablyReaderable`.

  `html` is a binary or a `%LazyHTML{}`, as in `article/2`. A document nested deeper than
  `:max_depth`, or in an encoding `article/2` rejects, isn't readerable. It can return `false`
  for a short article that `article/2` would extract.

  ## Options

  #{Options.readerable_docs()}
  """
  @spec readerable?(input(), keyword()) :: boolean()
  def readerable?(html, opts \\ []) do
    opts = Options.validate_readerable!(opts)

    case parse(html, opts.max_depth) do
      {:ok, lazy, utf8} -> not unsupported_charset?(lazy, utf8) and Readerable.readerable?(lazy, opts)
      {:error, :too_deep} -> false
    end
  end

  # Like `article/2`'s check, but looks at the declaration first: the tree is only needed then.
  defp unsupported_charset?(_lazy, :valid), do: false

  defp unsupported_charset?(lazy, :unknown),
    do: Charset.unsupported(lazy) != nil and Charset.mostly_invalid?(LazyHTML.to_tree(lazy))

  # Returns `{:ok, lazy, utf8}`: `:valid` when the input is known to be valid UTF-8, `:unknown`
  # for a `%LazyHTML{}` or a binary that isn't (LazyHTML keeps invalid UTF-8 as is; the tree is
  # checked and scrubbed instead, so both kinds of input are handled the same way).
  defp parse(%LazyHTML{} = lazy, _max_depth), do: {:ok, lazy, :unknown}

  defp parse(html, max_depth) when is_binary(html) do
    html = strip_bom(html)
    lazy = LazyHTML.from_document(html, if(max_depth == :infinity, do: [], else: [max_depth: max_depth]))
    {:ok, lazy, if(String.valid?(html, :fast_ascii), do: :valid, else: :unknown)}
  rescue
    # LazyHTML raises a RuntimeError for every limit; the depth limit is the only one set here.
    # Matching its message (LazyHTML 0.1.14) is checked by the ":max_depth limits the nesting"
    # test in test/readability_test.exs.
    error in RuntimeError ->
      if String.contains?(error.message, "nest deeper than :max_depth"),
        do: {:error, :too_deep},
        else: reraise(error, __STACKTRACE__)
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, html::binary>>), do: html
  defp strip_bom(html), do: html

  # Invalid UTF-8 in the tree is either another encoding the document declares (rejected, see
  # `Readability.Charset`), or replaced with U+FFFD per malformed sequence, as a decoder does.
  # A byte order mark ends up as the first text of a tree (LazyHTML keeps it), which can't be
  # told from a U+FEFF that was there, so that's dropped for both kinds of input.
  defp valid_tree(tree, _lazy, :valid), do: {:ok, DOM.drop_bom(tree)}

  defp valid_tree(tree, lazy, :unknown) do
    cond do
      DOM.valid_utf8?(tree) ->
        {:ok, DOM.drop_bom(tree)}

      (charset = Charset.unsupported(lazy)) && Charset.mostly_invalid?(tree) ->
        {:error, {:unsupported_charset, charset}}

      true ->
        {:ok, tree |> DOM.valid_utf8() |> DOM.drop_bom()}
    end
  end

  # `getElementsByTagName("*").length` on the document as parsed
  defp count_elements([], n), do: n
  defp count_elements([text | rest], n) when is_binary(text), do: count_elements(rest, n)
  defp count_elements([{_, _, children, _} | rest], n), do: count_elements(rest, count_elements(children, n + 1))

  defp build(article, metadata, grabbed) do
    text_content = DOM.text_content(article)

    %Article{
      title: copy(metadata.title),
      byline: copy(js_or(metadata.byline, grabbed.byline)),
      dir: copy(grabbed.dir),
      lang: copy(grabbed.lang),
      # built by appending, so it has room to grow that a copy doesn't keep
      content: article |> Serializer.inner_html() |> :binary.copy(),
      text_content: copy(text_content),
      length: Text.length(text_content),
      excerpt: copy(excerpt(metadata.excerpt, article)),
      site_name: copy(js_or(metadata.site_name, nil)),
      published_time: copy(metadata.published_time)
    }
  end

  # `a || b` on strings or nulls
  defp js_or(a, b) when a in [nil, ""], do: b
  defp js_or(a, _b), do: a

  # Without an excerpt in the metadata, the trimmed text of the article's first paragraph.
  defp excerpt(excerpt, article) when excerpt in [nil, ""] do
    case first_p(elem(article, 2)) do
      nil -> excerpt
      p -> p |> DOM.text_content() |> Text.trim()
    end
  end

  defp excerpt(excerpt, _article), do: excerpt

  defp first_p([]), do: nil
  defp first_p([{"p", _, _, _} = p | _]), do: p
  defp first_p([{_, _, children, _} | rest]), do: first_p(children) || first_p(rest)
  defp first_p([_text | rest]), do: first_p(rest)

  # Before lazy_html 0.1.15, strings from the parser's tree keep the whole parsed document alive.
  defp copy(nil), do: nil
  defp copy(bin), do: :binary.copy(bin)
end

defmodule Readability.Error do
  @moduledoc """
  Raised by `Readability.article!/2` when there's no article. `:reason` is one of
  `t:Readability.reason/0`.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: Readability.reason()}

  @impl true
  def message(%{reason: :not_readable}), do: "no article found in the document"
  def message(%{reason: :too_many_elements}), do: "the document has more elements than :max_elems_to_parse"
  def message(%{reason: :too_deep}), do: "the document's elements nest deeper than :max_depth"

  def message(%{reason: {:unsupported_charset, charset}}),
    do: "the document is encoded in #{charset}, not UTF-8: decode it to UTF-8 first"
end
