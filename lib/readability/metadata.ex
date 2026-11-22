defmodule Readability.Metadata do
  @moduledoc false
  # Article metadata (design §7 Stage 2): ports of `_getJSONLD`, `_getArticleMetadata`,
  # `_getArticleTitle` and `_isUrl`, plus `_articleLang` (the `lang` attribute of `<html>`, which
  # Readability.js reads during the grab walk; nothing changes it before that).
  #
  # `document.title` follows JSDOMParser, which the oracle runs on: the trimmed `textContent` of
  # the first `<title>` element (SVG ones included) whose trimmed text is not empty.

  alias Readability.{DOM, Matchers, Text, URL}

  @type json_ld :: %{
          optional(:title) => binary(),
          optional(:byline) => binary(),
          optional(:excerpt) => binary(),
          optional(:site_name) => binary(),
          optional(:date_published) => binary()
        }

  @type t :: %{
          title: binary() | nil,
          byline: binary() | nil,
          excerpt: binary() | nil,
          site_name: binary() | nil,
          published_time: binary() | nil,
          lang: binary() | nil
        }

  # ---------------------------------------------------------------------------------------------
  # _getJSONLD
  # ---------------------------------------------------------------------------------------------

  @doc """
  `_getJSONLD(doc)`: metadata from the first `<script type="application/ld+json">` that yields
  any (a schema.org object of an article type, possibly inside an array or `@graph`). Keys are
  present only when found. Invalid JSON and JS `TypeError`s are swallowed like upstream does.

  Run on the document before scripts are removed (after `_unwrapNoscriptImages`).
  """
  @spec json_ld(DOM.tree()) :: json_ld()
  def json_ld(doc) when is_list(doc) do
    doc
    |> DOM.find_all(["script"])
    |> Enum.find_value(%{}, fn script ->
      if DOM.attr(script, "type") == "application/ld+json", do: from_script(script, doc)
    end)
  end

  # nil when the script yields no metadata (`return` inside the forEach callback, or an exception)
  defp from_script(script, doc) do
    script |> DOM.text_content() |> Matchers.strip_cdata() |> decode() |> from_json(doc)
  catch
    :type_error -> nil
  end

  defp from_json(parsed, doc) do
    with {:ok, parsed} <- find_in_array(parsed),
         true <- schema_org_context?(get(parsed, "@context")),
         {:ok, parsed} <- find_in_graph(parsed),
         true <- article?(parsed) do
      extract_json_ld(parsed, doc)
    else
      _ -> nil
    end
  end

  defp find_in_array(list) when is_list(list) do
    case Enum.find(list, fn it ->
           type = get(it, "@type")
           truthy?(type) and match_type!(type)
         end) do
      nil -> :error
      parsed -> {:ok, parsed}
    end
  end

  defp find_in_array(parsed), do: {:ok, parsed}

  # `typeof ctx === "string" && ctx.match(re) || typeof ctx === "object" && typeof ctx["@vocab"] == "string" && ...`
  # (`typeof null` is "object", so a null `@context` throws on `["@vocab"]`).
  defp schema_org_context?(ctx) when is_binary(ctx), do: Matchers.schema_org?(ctx)

  defp schema_org_context?(ctx) when is_map(ctx) or is_list(ctx) or ctx == :null do
    vocab = get(ctx, "@vocab")
    is_binary(vocab) and Matchers.schema_org?(vocab)
  end

  defp schema_org_context?(_), do: false

  defp find_in_graph(parsed) do
    graph = get(parsed, "@graph")

    if not truthy?(get(parsed, "@type")) and is_list(graph),
      do: find_typed(graph),
      else: {:ok, parsed}
  end

  defp find_typed(graph) do
    case Enum.find(graph, fn it -> it |> get("@type") |> js_or("") |> match_type!() end) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  defp article?(parsed) do
    type = get(parsed, "@type")
    truthy?(type) and match_type!(type)
  end

  defp extract_json_ld(parsed, doc) do
    name = get(parsed, "name")
    headline = get(parsed, "headline")

    title =
      cond do
        is_binary(name) and is_binary(headline) and name != headline ->
          # some sites put their own name in "name" and the article title in "headline"
          title = article_title(collect(doc))
          name_matches = Text.text_similarity(name, title) > 0.75
          headline_matches = Text.text_similarity(headline, title) > 0.75
          if headline_matches and not name_matches, do: headline, else: name

        is_binary(name) ->
          Text.trim(name)

        is_binary(headline) ->
          Text.trim(headline)

        true ->
          nil
      end

    %{}
    |> put_present(:title, title)
    |> put_present(:byline, json_ld_byline(get(parsed, "author")))
    |> put_present(:excerpt, trimmed_string(get(parsed, "description")))
    |> put_present(:site_name, json_ld_site_name(get(parsed, "publisher")))
    |> put_present(:date_published, trimmed_string(get(parsed, "datePublished")))
  end

  defp json_ld_byline(author) do
    cond do
      not truthy?(author) ->
        nil

      is_binary(get(author, "name")) ->
        Text.trim(get(author, "name"))

      is_list(author) and author != [] and truthy?(hd(author)) and is_binary(get(hd(author), "name")) ->
        Enum.map_join(
          for(a <- author, truthy?(a), name = get(a, "name"), is_binary(name), do: name),
          ", ",
          &Text.trim/1
        )

      true ->
        nil
    end
  end

  defp json_ld_site_name(publisher) do
    if truthy?(publisher), do: trimmed_string(get(publisher, "name"))
  end

  defp trimmed_string(s) when is_binary(s), do: Text.trim(s)
  defp trimmed_string(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # --- JS values -------------------------------------------------------------------------------
  # JSON null is `:null`; `nil` is JS `undefined` (a missing property).

  # `JSON.parse`: duplicate keys keep the last value; numbers out of float range are Infinity
  # (only their truthiness and type matter here).
  defp decode(json) do
    {value, :ok, rest} = :json.decode(json, :ok, %{object_finish: &object_finish/2, float: &float/1})
    if json_ws?(rest), do: value, else: throw(:type_error)
  rescue
    _ -> throw(:type_error)
  end

  defp object_finish(acc, old), do: {Map.new(:lists.reverse(acc)), old}

  defp float(bin) do
    :erlang.binary_to_float(bin)
  rescue
    ArgumentError -> :infinity
  end

  defp json_ws?(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: json_ws?(rest)
  defp json_ws?(<<>>), do: true
  defp json_ws?(_), do: false

  # `value[key]`: throws on null and undefined, like JS.
  defp get(map, key) when is_map(map), do: Map.get(map, key)
  defp get(value, _key) when value == nil or value == :null, do: throw(:type_error)
  defp get(_value, _key), do: nil

  defp truthy?(value), do: value not in [nil, :null, false, "", 0] and value != 0.0

  defp js_or(value, default), do: if(truthy?(value), do: value, else: default)

  # `value.match(REGEXPS.jsonLdArticleTypes)`: only strings have `match`.
  defp match_type!(value) when is_binary(value), do: Matchers.jsonld_article_type?(value)
  defp match_type!(_value), do: throw(:type_error)

  # ---------------------------------------------------------------------------------------------
  # _getArticleMetadata
  # ---------------------------------------------------------------------------------------------

  @doc """
  `_getArticleMetadata(jsonld)` plus the document's `lang`. Run on the prepared document; pass
  `%{}` for `json_ld` when JSON-LD is disabled. Every value is a binary not referencing the
  parser's binaries, or `nil`.
  """
  @spec extract(DOM.tree(), json_ld()) :: t()
  def extract(doc, json_ld) when is_list(doc) and is_map(json_ld) do
    page = collect(doc)
    values = meta_values(page.metas)
    v = &Map.get(values, &1)

    title =
      js_or([
        json_ld[:title],
        v.("dc:title"),
        v.("dcterm:title"),
        v.("og:title"),
        v.("weibo:article:title"),
        v.("weibo:webpage:title"),
        v.("title"),
        v.("twitter:title"),
        v.("parsely-title")
      ])

    title = if truthy?(title), do: title, else: article_title(page)

    article_author =
      case v.("article:author") do
        author when is_binary(author) -> if URL.url?(author), do: nil, else: author
        nil -> nil
      end

    byline =
      js_or([
        json_ld[:byline],
        v.("dc:creator"),
        v.("dcterm:creator"),
        v.("author"),
        v.("parsely-author"),
        article_author
      ])

    excerpt =
      js_or([
        json_ld[:excerpt],
        v.("dc:description"),
        v.("dcterm:description"),
        v.("og:description"),
        v.("weibo:article:description"),
        v.("weibo:webpage:description"),
        v.("description"),
        v.("twitter:description")
      ])

    site_name = js_or([json_ld[:site_name], v.("og:site_name")])

    published_time =
      js_or([json_ld[:date_published], v.("article:published_time"), v.("parsely-pub-date"), nil])

    %{
      title: output(title),
      byline: output(byline),
      excerpt: output(excerpt),
      site_name: output(site_name),
      published_time: output(published_time),
      lang: copy(page.lang)
    }
  end

  # JS `a || b || ... || z`: the first truthy value, else the last one.
  defp js_or([last]), do: last
  defp js_or([value | rest]), do: if(truthy?(value), do: value, else: js_or(rest))

  defp output(value), do: value |> Text.unescape_html_entities() |> copy()

  defp copy(nil), do: nil
  defp copy(bin), do: :binary.copy(bin)

  # `values[name] = content.trim()` for every `<meta>` whose property or name matches; later ones win.
  defp meta_values(metas) do
    Enum.reduce(metas, %{}, fn meta, values ->
      content = DOM.attr(meta, "content")
      key = content not in [nil, ""] and (property_key(DOM.attr(meta, "property")) || name_key(DOM.attr(meta, "name")))
      if key, do: Map.put(values, key, Text.trim(content)), else: values
    end)
  end

  defp property_key(nil), do: nil
  defp property_key(""), do: nil
  defp property_key(property), do: Matchers.meta_property_key(property)

  defp name_key(nil), do: nil
  defp name_key(""), do: nil
  defp name_key(name), do: Matchers.meta_name_key(name)

  # ---------------------------------------------------------------------------------------------
  # Document scan
  # ---------------------------------------------------------------------------------------------

  # One pass over the document: `<meta>` elements, `document.title`, `<h1>`s and `<h1>`/`<h2>`s
  # (all in document order) and `<html lang>`.
  defp collect(doc) do
    {metas, title, h1s, headings} = collect_list(doc, {[], nil, [], []})

    %{
      metas: :lists.reverse(metas),
      title: title || "",
      h1s: :lists.reverse(h1s),
      headings: :lists.reverse(headings),
      lang: Enum.find_value(doc, fn node -> match?({"html", _, _, _}, node) && DOM.attr(node, "lang") end)
    }
  end

  defp collect_list([], acc), do: acc
  defp collect_list([text | rest], acc) when is_binary(text), do: collect_list(rest, acc)

  defp collect_list([{tag, _, children, _} = el | rest], {metas, title, h1s, headings} = acc) do
    acc =
      case tag do
        "meta" ->
          {[el | metas], title, h1s, headings}

        "h1" ->
          {metas, title, [el | h1s], [el | headings]}

        "h2" ->
          {metas, title, h1s, [el | headings]}

        "title" when title == nil ->
          case el |> DOM.text_content() |> Text.trim() do
            "" -> acc
            text -> {metas, text, h1s, headings}
          end

        _ ->
          acc
      end

    collect_list(rest, collect_list(children, acc))
  end

  # ---------------------------------------------------------------------------------------------
  # _getArticleTitle
  # ---------------------------------------------------------------------------------------------

  @doc false
  # `_getArticleTitle()` on a collected page.
  def article_title(%{title: orig} = page) do
    separator = Matchers.regex(:title_separator)
    {cur, hierarchical?} = title_candidate(orig, separator, page)
    cur = cur |> Text.trim() |> Text.normalize()
    word_count = Text.word_count(cur)

    # 4 words or fewer, and either no hierarchical separators or more than one word dropped
    if word_count <= 4 and
         (not hierarchical? or word_count != Text.word_count(Regex.replace(separator, orig, "")) - 1),
       do: orig,
       else: cur
  end

  # {title, whether it had hierarchical separators}
  defp title_candidate(orig, separator, page) do
    cond do
      Regex.match?(separator, orig) ->
        {separator_title(orig, separator), Regex.match?(Matchers.regex(:title_hierarchical_separator), orig)}

      :binary.match(orig, ": ") != :nomatch ->
        # a heading with exactly this text means the colon belongs to the title
        if Enum.any?(page.headings, &(&1 |> DOM.text_content() |> Text.trim() == orig)),
          do: {orig, false},
          else: {colon_title(orig), false}

      (len = Text.length(orig)) > 150 or len < 15 ->
        case page.h1s do
          [h1] -> {DOM.inner_text(h1), false}
          _ -> {orig, false}
        end

      true ->
        {orig, false}
    end
  end

  # The title up to the last separator; if that is too short, without the first part instead.
  defp separator_title(orig, separator) do
    [[{last, _}] | _] = separator |> Regex.scan(orig, return: :index) |> :lists.reverse()
    cur = binary_part(orig, 0, last)

    if Text.word_count(cur) < 3,
      do: Regex.replace(Matchers.regex(:title_first_part), orig, "", global: false),
      else: cur
  end

  defp colon_title(orig) do
    {first, _} = :binary.match(orig, ":")
    {last, _} = orig |> :binary.matches(":") |> List.last()
    after_last = binary_part(orig, last + 1, byte_size(orig) - last - 1)

    cond do
      # too short: use the part after the first colon instead
      Text.word_count(after_last) < 3 -> binary_part(orig, first + 1, byte_size(orig) - first - 1)
      # too many words before the colon: something's off, keep the original
      Text.word_count(binary_part(orig, 0, first)) > 5 -> orig
      true -> after_last
    end
  end
end
