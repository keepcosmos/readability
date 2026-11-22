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

  alias Readability.{Article, Clean, DOM, Grab, Metadata, Options, PostProcess, Prep, Readerable, Text, URL}
  alias Readability.DOM.Serializer

  @typedoc "An HTML document, as a string or parsed with `LazyHTML.from_document/2`."
  @type input :: String.t() | LazyHTML.t()

  @typedoc """
  Why there's no article:

    * `:not_readable` - nothing that looks like an article was found (Readability.js returns `null`);
    * `:too_many_elements` - the document has more elements than `:max_elems_to_parse`
      (Readability.js throws).
  """
  @type reason :: :not_readable | :too_many_elements

  @readerable_schema NimbleOptions.new!(
                       min_content_length: [
                         type: :pos_integer,
                         default: 140,
                         doc: "The minimum length of a paragraph's text for it to count."
                       ],
                       min_score: [
                         type: {:or, [:integer, :float]},
                         default: 20,
                         doc: "The score, summed over the paragraphs that count, the page must exceed."
                       ]
                     )

  @doc """
  Extracts the article from `html`, like Readability.js's `parse()`.

  `html` is a binary (a leading UTF-8 byte order mark is ignored) or a `%LazyHTML{}` parsed with
  `LazyHTML.from_document/2`. Pass a `%LazyHTML{}` to set LazyHTML's parsing limits (`:max_depth`,
  `:max_memory`, ...) for untrusted input, or to parse once for both `readerable?/2` and
  `article/2`.

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
    if opts.spawn, do: in_process(fn -> extract(html, opts) end, html), else: extract(html, opts)
  end

  defp extract(html, opts) do
    doc = html |> parse() |> LazyHTML.to_tree() |> DOM.from_lazy()
    ctx = if opts.max_elems_to_parse > 0, do: %{element_count: count_elements(doc, 0)}, else: %{}

    doc = Prep.unwrap_noscript_images(doc)
    json_ld = if opts.disable_json_ld, do: %{}, else: Metadata.json_ld(doc)
    doc = Prep.prep_document(doc)
    metadata = Metadata.extract(doc, json_ld)

    ctx = Map.merge(ctx, %{article_title: metadata.title, metadata_byline: metadata.byline})

    with {:ok, grabbed} <- Grab.run(doc, ctx, opts, &Clean.prep_article(&1, &2, opts)) do
      base_uri = URL.base_uri(opts.url, base_href(doc))
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

  `html` is a binary or a `%LazyHTML{}`, as in `article/2`.

  ## Options

  #{NimbleOptions.docs(@readerable_schema)}
  """
  @spec readerable?(input(), keyword()) :: boolean()
  def readerable?(html, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @readerable_schema)
    Readerable.readerable?(parse(html), opts)
  end

  # Runs `fun` in a linked process and returns its result (or raises what it raised). The heap
  # starts at one word per byte of HTML: the tree and its rebuilt copies need about that much,
  # and growing to it step by step makes the GC copy the tree over and over (design §8: half of
  # the time on large pages). The garbage goes away with the process, unscanned.
  defp in_process(fun, html) do
    caller = self()

    {heap, limit} =
      case Process.info(caller, :max_heap_size) do
        {:max_heap_size, %{size: size} = max} when size > 0 -> {div(size, 2), [max_heap_size: max]}
        _ -> {:infinity, []}
      end

    heap = if is_binary(html), do: [min_heap_size: min(byte_size(html), heap)], else: []

    worker = fn ->
      result =
        try do
          {:ok, fun.()}
        catch
          kind, reason -> {:raise, kind, reason, __STACKTRACE__}
        end

      send(caller, {self(), result})
    end

    {pid, ref} = :erlang.spawn_opt(worker, [:link, :monitor | heap ++ limit])

    receive do
      {^pid, result} ->
        # No `{:EXIT, pid, :normal}` for a caller that traps exits.
        Process.unlink(pid)
        Process.demonitor(ref, [:flush])

        receive do
          {:EXIT, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        case result do
          {:ok, value} -> value
          {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
        end

      # Killed (by its `:max_heap_size`, or an exit signal). Without trapping exits the link
      # has taken the caller down already.
      {:DOWN, ^ref, :process, ^pid, reason} ->
        receive do
          {:EXIT, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        exit(reason)
    end
  end

  defp parse(%LazyHTML{} = lazy), do: lazy
  defp parse(<<0xEF, 0xBB, 0xBF, html::binary>>), do: LazyHTML.from_document(html)
  defp parse(html) when is_binary(html), do: LazyHTML.from_document(html)

  # `getElementsByTagName("*").length` on the document as parsed
  defp count_elements([], n), do: n
  defp count_elements([text | rest], n) when is_binary(text), do: count_elements(rest, n)
  defp count_elements([{_, _, children, _} | rest], n), do: count_elements(rest, count_elements(children, n + 1))

  # The `href` of the first `<base>` (JSDOMParser's `baseURI`)
  defp base_href(doc) do
    case DOM.find_all(doc, ["base"]) do
      [base | _] -> DOM.attr(base, "href")
      [] -> nil
    end
  end

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
end
