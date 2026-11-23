defmodule Readability do
  @moduledoc """
  Extracts the main content of a web page: a port of Mozilla's
  [Readability.js](https://github.com/mozilla/readability), the library behind Firefox's Reader
  View, on top of [LazyHTML](https://hexdocs.pm/lazy_html).

      {:ok, article} = Readability.article(html, url: "https://example.com/post")
      article.title
      article.content       #=> "<div id=\\"readability-page-1\\" class=\\"page\\">…</div>"
      article.text_content

  See `Readability.Article` for the fields. Fetching the page is up to you.

  ## Options

  #{Readability.Options.docs()}
  """

  alias Readability.{Article, Clean, DOM, Grab, Metadata, Options, PostProcess, Prep, Readerable, Text, URL, Worker}
  alias Readability.DOM.Serializer

  @typedoc "An HTML document, as a string or parsed with `LazyHTML.from_document/2`."
  @type input :: String.t() | LazyHTML.t()

  @typedoc """
  Why there's no article:

    * `:not_readable` - nothing that looks like an article was found (Readability.js returns `null`);
    * `:too_many_elements` - the document has more elements than `:max_elems_to_parse`
      (Readability.js throws);
    * `:too_deep` - the document's elements nest deeper than `:max_depth`.
  """
  @type reason :: :not_readable | :too_many_elements | :too_deep

  @doc """
  Extracts the article from `html`, like Readability.js's `parse()`.

  `html` is a binary (a leading UTF-8 byte order mark is ignored) or a `%LazyHTML{}` parsed with
  `LazyHTML.from_document/2`. A binary is parsed with the `:max_depth` option as LazyHTML's depth
  limit. A `%LazyHTML{}` is used as is: parse it yourself to choose LazyHTML's limits
  (`:max_depth`, `:max_memory`, `:timeout`, ...) for untrusted input, or to parse once for both
  `readerable?/2` and `article/2`.

  Options are listed in the [module documentation](#module-options). Invalid options raise
  `NimbleOptions.ValidationError`.

      iex> html = "<html><body><article><p>#{String.duplicate("Some text here. ", 40)}</p></article></body></html>"
      iex> {:ok, article} = Readability.article(html)
      iex> article.length
      640

      iex> Readability.article("<html><body></body></html>")
      {:error, :not_readable}
  """
  @spec article(input(), keyword()) :: {:ok, Article.t()} | {:error, reason()}
  def article(html, opts \\ []) do
    opts = Options.validate!(opts)
    if opts.spawn, do: Worker.run(fn -> run(html, opts) end, html), else: run(html, opts)
  end

  defp run(html, opts) do
    case parse(html, opts.max_depth) do
      {:ok, lazy} -> run_parsed(lazy, html, opts)
      error -> error
    end
  end

  defp run_parsed(lazy, html, opts) do
    doc = lazy |> LazyHTML.to_tree() |> valid_tree(html) |> DOM.from_lazy()
    max = opts.max_elems_to_parse
    count = if max > 0, do: count_elements(doc, 0), else: 0

    # `parse()` checks the count before doing anything else
    if max > 0 and count > max,
      do: {:error, :too_many_elements},
      else: extract(doc, %{element_count: count}, opts)
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
  `:max_depth` isn't readerable.

  ## Options

  #{Options.readerable_docs()}
  """
  @spec readerable?(input(), keyword()) :: boolean()
  def readerable?(html, opts \\ []) do
    opts = Options.validate_readerable!(opts)

    case parse(html, opts.max_depth) do
      {:ok, lazy} -> Readerable.readerable?(lazy, opts)
      {:error, :too_deep} -> false
    end
  end

  defp parse(%LazyHTML{} = lazy, _max_depth), do: {:ok, lazy}

  defp parse(html, max_depth) when is_binary(html) do
    html = html |> strip_bom() |> valid_utf8()
    {:ok, LazyHTML.from_document(html, if(max_depth == :infinity, do: [], else: [max_depth: max_depth]))}
  rescue
    # LazyHTML raises a RuntimeError for every limit; the depth limit is the only one set here.
    error in RuntimeError ->
      if String.contains?(error.message, "nest deeper than :max_depth"),
        do: {:error, :too_deep},
        else: reraise(error, __STACKTRACE__)
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, html::binary>>), do: html
  defp strip_bom(html), do: html

  # LazyHTML keeps invalid UTF-8 as is; a decoder replaces each malformed sequence with U+FFFD.
  defp valid_utf8(html), do: if(String.valid?(html, :fast_ascii), do: html, else: String.replace_invalid(html))

  # A `%LazyHTML{}` passed in may have been parsed from invalid UTF-8: scrub its tree the same way.
  defp valid_tree(tree, %LazyHTML{}), do: DOM.valid_utf8(tree)
  defp valid_tree(tree, _html), do: tree

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
      content: Serializer.inner_html(article),
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

  # Strings from the parser's tree keep the whole parsed document alive.
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
end
