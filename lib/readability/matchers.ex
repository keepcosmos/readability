defmodule Readability.Matchers do
  @moduledoc false
  # Readability.js's `REGEXPS` and inline regexes, implemented per design §6.
  #
  # Per-node tests (class/id keyword sets, image extensions, `shareElements`, `hashUrl`, the
  # lazy-image and `b64DataUrl` patterns) are compile-time generated or hand-written binary
  # matchers. Everything else is a cold regex compiled once into `:persistent_term`, see
  # `regex/1`. Agreement with the JS regexes is tested against Node-generated fixtures.
  #
  # JS `/i` without `u` folds ASCII only (a non-ASCII character never matches an ASCII pattern
  # character), so lower-casing ASCII and matching lower-case literals is exact.
  #
  # Not here, because they belong to `Readability.Text` (per-text-node scanners): `whitespace`,
  # `hasContent`, `normalize`, `tokenize`, `commas`, `split(/\s+/)` and entity unescaping.

  # ---------------------------------------------------------------------------------------------
  # Keyword sets
  # ---------------------------------------------------------------------------------------------

  @unlikely ~w(-ad- ai2html banner breadcrumbs combx comment community cover-wrap disqus extra footer gdpr
               header legends menu related remark replies rss shoutbox sidebar skyscraper social sponsor
               supplemental ad-break agegate pagination pager popup yom-remote)
  @maybe ~w(and article body column content main mathjax shadow)
  @positive ~w(article body content entry hentry h-entry main page pagination post text blog story)
  # plus the anchored "hid" alternatives `^hid$| hid$| hid |^hid ` (literal spaces), see negative?/1
  @negative ~w(-ad- hidden banner combx comment com- contact footer gdpr masthead media meta outbrain promo
               related scroll share shoutbox sidebar skyscraper sponsor shopping tags widget)
  @byline ~w(byline author dateline writtenby p-author)
  @image_ext ~w(.jpg .jpeg .png .webp)

  # One self-recursive scanner per set: every clause starts with a binary match, so the match
  # context is reused across positions. The compiler turns the literal prefixes into a decision
  # tree on the first byte.
  for {name, words} <- [
        unlikely: @unlikely,
        maybe: @maybe,
        positive: @positive,
        negative: @negative,
        byline: @byline,
        image_ext: @image_ext
      ] do
    scan = :"#{name}_scan"

    for word <- Enum.sort_by(words, &(-byte_size(&1))) do
      defp unquote(scan)(<<unquote(word), _::binary>>), do: true
    end

    # `negative`: " hid " anywhere, or " hid" at the end (the `^hid` forms are in negative?/1)
    if name == :negative do
      defp negative_scan(<<" hid ", _::binary>>), do: true
      defp negative_scan(<<" hid">>), do: true
    end

    defp unquote(scan)(<<_, rest::binary>>), do: unquote(scan)(rest)
    defp unquote(scan)(<<>>), do: false
  end

  @doc "ASCII lower-case. Returns the argument itself when it has no upper-case ASCII letter."
  @spec lower(binary) :: binary
  def lower(s), do: if(upper?(s), do: do_lower(s, <<>>), else: s)

  defp upper?(<<c, _::binary>>) when c in ?A..?Z, do: true
  defp upper?(<<_, r::binary>>), do: upper?(r)
  defp upper?(<<>>), do: false

  defp do_lower(<<c, r::binary>>, acc) when c in ?A..?Z, do: do_lower(r, <<acc::binary, c + 32>>)
  defp do_lower(<<c, r::binary>>, acc), do: do_lower(r, <<acc::binary, c>>)
  defp do_lower(<<>>, acc), do: acc

  @doc "`REGEXPS.unlikelyCandidates.test(s)`"
  def unlikely?(s), do: unlikely_scan(lower(s))
  @doc "`REGEXPS.okMaybeItsACandidate.test(s)`"
  def maybe_candidate?(s), do: maybe_scan(lower(s))
  @doc "`REGEXPS.positive.test(s)`"
  def positive?(s), do: positive_scan(lower(s))
  @doc "`REGEXPS.byline.test(s)`"
  def byline?(s), do: byline_scan(lower(s))
  @doc "`/\\.(jpg|jpeg|png|webp)/i.test(s)`"
  def image_ext?(s), do: image_ext_scan(lower(s))

  @doc "`REGEXPS.negative.test(s)`"
  def negative?(s), do: negative_lower?(lower(s))

  defp negative_lower?("hid"), do: true
  defp negative_lower?(<<"hid ", _::binary>>), do: true
  defp negative_lower?(s), do: negative_scan(s)

  @doc """
  `unlikelyCandidates.test(m) && !okMaybeItsACandidate.test(m)` for `m = className + " " + id`
  (`_grabArticle`, `isProbablyReaderable`). No keyword contains a space, so class and id are
  matched separately without building `m`. `nil` stands for a missing attribute.
  """
  @spec unlikely_candidate?(binary | nil, binary | nil) :: boolean
  def unlikely_candidate?(class, id) do
    class = lower(class || "")
    id = lower(id || "")
    (unlikely_scan(class) or unlikely_scan(id)) and not (maybe_scan(class) or maybe_scan(id))
  end

  @doc "`REGEXPS.byline.test(className + \" \" + id)`"
  @spec byline?(binary | nil, binary | nil) :: boolean
  def byline?(class, id), do: byline_scan(lower(class || "")) or byline_scan(lower(id || ""))

  @doc """
  The class/id part of `_getClassWeight` (without the `FLAG_WEIGHT_CLASSES` check): -25 for a
  negative and +25 for a positive match, for the class and the id each.
  """
  @spec class_weight(binary | nil, binary | nil) :: integer
  def class_weight(class, id), do: weight(class) + weight(id)

  defp weight(nil), do: 0
  defp weight(""), do: 0

  defp weight(s) do
    s = lower(s)
    w = if negative_lower?(s), do: -25, else: 0
    if positive_scan(s), do: w + 25, else: w
  end

  # ---------------------------------------------------------------------------------------------
  # shareElements: /(\b|_)(share|sharedaddy)(\b|_)/i, hand-written. `\b` is ASCII here, so the
  # test is: "share" (or "sharedaddy") not preceded and not followed by [a-z0-9].
  # ---------------------------------------------------------------------------------------------

  @doc "`REGEXPS.shareElements.test(s)`"
  @spec share_element?(binary) :: boolean
  def share_element?(s), do: share_scan(lower(s), false)

  @doc "`REGEXPS.shareElements.test(className + \" \" + id)`"
  @spec share_element?(binary | nil, binary | nil) :: boolean
  def share_element?(class, id), do: share_element?(class || "") or share_element?(id || "")

  defp share_scan(<<"share", rest::binary>>, false), do: share_tail?(rest) or share_scan(rest, true)
  defp share_scan(<<c, rest::binary>>, _) when c in ?a..?z or c in ?0..?9, do: share_scan(rest, true)
  defp share_scan(<<_, rest::binary>>, _), do: share_scan(rest, false)
  defp share_scan(<<>>, _), do: false

  defp share_tail?(<<c, _::binary>> = rest) when c in ?a..?z or c in ?0..?9 do
    case rest do
      <<"daddy", c, _::binary>> when c in ?a..?z or c in ?0..?9 -> false
      <<"daddy", _::binary>> -> true
      _ -> false
    end
  end

  defp share_tail?(_), do: true

  # ---------------------------------------------------------------------------------------------
  # Small hand-written patterns
  # ---------------------------------------------------------------------------------------------

  @doc "`REGEXPS.hashUrl.test(s)`: `/^#.+/`; JS `.` excludes \\n, \\r, U+2028 and U+2029."
  @spec hash_url?(binary) :: boolean
  def hash_url?(<<"#", c, _::binary>>) when c == ?\n or c == ?\r, do: false
  def hash_url?(<<"#", 0xE2, 0x80, c, _::binary>>) when c == 0xA8 or c == 0xA9, do: false
  def hash_url?(<<"#", _, _::binary>>), do: true
  def hash_url?(_), do: false

  @doc "`/\\.( |$)/` (`_grabArticle` sibling loop): \". \" anywhere or a final \".\"."
  @spec sentence_end?(binary) :: boolean
  def sentence_end?(s), do: :binary.match(s, ". ") != :nomatch or (s != "" and :binary.last(s) == ?.)

  @doc "`className.toLowerCase().includes(\"lazy\")` (`_fixLazyImages`)."
  @spec lazy_class?(binary | nil) :: boolean
  def lazy_class?(nil), do: false
  def lazy_class?(class), do: :binary.match(lower(class), "lazy") != :nomatch

  @doc "`/\\.(jpg|jpeg|png|webp)\\s+\\d/.test(s)` (case-sensitive; `_fixLazyImages` srcset test)."
  @spec lazy_srcset?(binary) :: boolean
  def lazy_srcset?(s), do: lazy_srcset_scan(s)

  defp lazy_srcset_scan(<<".jpg", r::binary>>), do: ws_digit?(r) or lazy_srcset_scan(r)
  defp lazy_srcset_scan(<<".jpeg", r::binary>>), do: ws_digit?(r) or lazy_srcset_scan(r)
  defp lazy_srcset_scan(<<".png", r::binary>>), do: ws_digit?(r) or lazy_srcset_scan(r)
  defp lazy_srcset_scan(<<".webp", r::binary>>), do: ws_digit?(r) or lazy_srcset_scan(r)
  defp lazy_srcset_scan(<<_, r::binary>>), do: lazy_srcset_scan(r)
  defp lazy_srcset_scan(<<>>), do: false

  defp ws_digit?(s) do
    case skip_ws(s) do
      {0, _} -> false
      {_, <<c, _::binary>>} -> c in ?0..?9
      _ -> false
    end
  end

  @doc """
  `/^\\s*\\S+\\.(jpg|jpeg|png|webp)\\S*\\s*$/.test(s)` (case-sensitive; `_fixLazyImages` src
  test): after trimming, no whitespace left and an extension at index 1 or later.
  """
  @spec lazy_src?(binary) :: boolean
  def lazy_src?(s) do
    {_, s} = skip_ws(s)

    case s do
      <<_, rest::binary>> -> lazy_src_scan(rest, false)
      _ -> false
    end
  end

  defp lazy_src_scan(<<".jpg", r::binary>>, _), do: lazy_src_scan(r, true)
  defp lazy_src_scan(<<".jpeg", r::binary>>, _), do: lazy_src_scan(r, true)
  defp lazy_src_scan(<<".png", r::binary>>, _), do: lazy_src_scan(r, true)
  defp lazy_src_scan(<<".webp", r::binary>>, _), do: lazy_src_scan(r, true)
  defp lazy_src_scan(<<>>, found), do: found

  defp lazy_src_scan(s, found) do
    case ws_size(s) do
      0 ->
        <<_, r::binary>> = s
        lazy_src_scan(r, found)

      _ ->
        found and skip_ws(s) |> elem(1) == ""
    end
  end

  @doc """
  `REGEXPS.b64DataUrl.exec(s)`: `/^data:\\s*([^\\s;,]+)\\s*;\\s*base64\\s*,/i`. Returns
  `{mime, rest}` where `rest` follows the match (`s.length - parts[0].length` is its length),
  or `nil`.
  """
  @spec b64_data_url(binary) :: {binary, binary} | nil
  def b64_data_url(<<d, a, t, a2, ?:, rest::binary>>)
      when d in ~c"dD" and a in ~c"aA" and t in ~c"tT" and a2 in ~c"aA" do
    {_, rest} = skip_ws(rest)
    {mime, rest} = mime(rest, 0)

    with true <- mime != "",
         {_, <<";", rest::binary>>} <- skip_ws(rest),
         {_, <<b1, b2, b3, b4, ?6, ?4, rest::binary>>} <- skip_ws(rest),
         "base" <- lower(<<b1, b2, b3, b4>>),
         {_, <<",", rest::binary>>} <- skip_ws(rest) do
      {mime, rest}
    else
      _ -> nil
    end
  end

  def b64_data_url(_), do: nil

  defp mime(s, i) do
    case s do
      <<_::binary-size(^i), c, _::binary>> when c == ?; or c == ?, ->
        split_at(s, i)

      <<_::binary-size(^i), r::binary>> ->
        if r == "" or ws_size(r) > 0, do: split_at(s, i), else: mime(s, i + 1)
    end
  end

  defp split_at(s, i), do: {binary_part(s, 0, i), binary_part(s, i, byte_size(s) - i)}

  @doc """
  `srcset.replace(REGEXPS.srcsetUrl, (_, p1, p2, p3) => fun.(p1, p2 || "", p3))` with
  `srcsetUrl = /(\\S+)(\\s+[\\d.]+[xw])?(\\s*(?:,|$))/g`, in one linear pass (the regex is
  quadratic on a long run of non-whitespace with no match: it retries at every position).

  How the regex resolves at a run of non-whitespace `s[i..e)` (a match can only start at a
  run's first character; if it fails there it fails at every later position in the run):

    1. `p1` = the whole run, `p2` = whitespace, `[\\d.]+`, then `x`/`w`, `p3` = whitespace up to
       a `,` (included) or the end of the string;
    2. else `p1` = the whole run, no `p2`, `p3` = the whitespace after it up to a `,` (included)
       or the end of the string;
    3. else (backtracking `\\S+`) `p1` = the run up to its LAST `,` after `s[i]`, `p3` = `","`;
    4. else no match: the run is copied and scanning resumes after it.

  Scanning resumes after the match. Text between matches is copied unchanged.
  """
  @spec srcset_replace(binary, (binary, binary, binary -> iodata)) :: binary
  def srcset_replace(srcset, fun), do: IO.iodata_to_binary(srcset_scan(srcset, srcset, 0, 0, fun, []))

  # `s` is the rest of `o` at byte offset `pos`; `copy` is where the pending unchanged text starts.
  defp srcset_scan(<<>>, o, pos, copy, _fun, acc), do: [acc | binary_part(o, copy, pos - copy)]

  defp srcset_scan(s, o, pos, copy, fun, acc) do
    case ws_size(s) do
      0 ->
        {e, comma, rest} = srcset_run(s, pos, nil)

        case srcset_match(o, pos, e, comma, rest) do
          nil ->
            srcset_scan(rest, o, e, copy, fun, acc)

          {p1_end, p2_end, p3_end} ->
            p1 = binary_part(o, pos, p1_end - pos)
            p2 = binary_part(o, p1_end, p2_end - p1_end)
            p3 = binary_part(o, p2_end, p3_end - p2_end)
            acc = [acc, binary_part(o, copy, pos - copy) | fun.(p1, p2, p3)]
            <<_::binary-size(^p3_end), rest::binary>> = o
            srcset_scan(rest, o, p3_end, p3_end, fun, acc)
        end

      n ->
        <<_::binary-size(^n), rest::binary>> = s
        srcset_scan(rest, o, pos + n, copy, fun, acc)
    end
  end

  # Ends a run of non-whitespace: {end offset, offset of its last ",", rest at the end}.
  defp srcset_run(<<c, _::binary>> = s, pos, comma) when c == 32 or c in 9..13, do: {pos, comma, s}
  defp srcset_run(<<0xC2, 0xA0, _::binary>> = s, pos, comma), do: {pos, comma, s}
  defp srcset_run(<<0xE1, 0x9A, 0x80, _::binary>> = s, pos, comma), do: {pos, comma, s}

  defp srcset_run(<<0xE2, 0x80, c, _::binary>> = s, pos, comma) when c in 0x80..0x8A or c in [0xA8, 0xA9, 0xAF],
    do: {pos, comma, s}

  defp srcset_run(<<0xE2, 0x81, 0x9F, _::binary>> = s, pos, comma), do: {pos, comma, s}
  defp srcset_run(<<0xE3, 0x80, 0x80, _::binary>> = s, pos, comma), do: {pos, comma, s}
  defp srcset_run(<<0xEF, 0xBB, 0xBF, _::binary>> = s, pos, comma), do: {pos, comma, s}
  defp srcset_run(<<?,, r::binary>>, pos, _comma), do: srcset_run(r, pos + 1, pos)
  defp srcset_run(<<_, r::binary>>, pos, comma), do: srcset_run(r, pos + 1, comma)
  defp srcset_run(<<>>, pos, comma), do: {pos, comma, <<>>}

  # The match of a run starting at `i` and ending at `e` (`rest` follows it), as the end offsets
  # of p1, p2 and p3, or nil.
  defp srcset_match(o, i, e, comma, rest) do
    {ws, after_ws} = skip_ws(rest)
    f = byte_size(o) - byte_size(after_ws)

    with_descriptor =
      if ws > 0 do
        case srcset_descriptor(after_ws, 0) do
          {d, rest} -> srcset_tail(rest, e, f + d)
          nil -> nil
        end
      end

    cond do
      with_descriptor != nil -> with_descriptor
      after_ws == "" -> {e, e, f}
      match?(<<?,, _::binary>>, after_ws) -> {e, e, f + 1}
      comma != nil and comma > i -> {comma, comma, comma + 1}
      true -> nil
    end
  end

  # `[\d.]+[xw]`: {length, rest} or nil
  defp srcset_descriptor(<<c, r::binary>>, n) when c in ?0..?9 or c == ?., do: srcset_descriptor(r, n + 1)
  defp srcset_descriptor(<<c, r::binary>>, n) when n > 0 and (c == ?x or c == ?w), do: {n + 1, r}
  defp srcset_descriptor(_, _), do: nil

  # `\s*(?:,|$)` after a descriptor ending at `p2_end`
  defp srcset_tail(s, p1_end, p2_end) do
    {_, after_ws} = skip_ws(s)
    p3_end = p2_end + byte_size(s) - byte_size(after_ws)

    case after_ws do
      "" -> {p1_end, p2_end, p3_end}
      <<?,, _::binary>> -> {p1_end, p2_end, p3_end + 1}
      _ -> nil
    end
  end

  # JS `\s`: TAB LF VT FF CR SP U+00A0 U+1680 U+2000-200A U+2028 U+2029 U+202F U+205F U+3000 U+FEFF.
  # (A private copy; `Readability.Text` owns the shared one.)
  defp ws_size(<<c, _::binary>>) when c == 32 or c in 9..13, do: 1
  defp ws_size(<<0xC2, 0xA0, _::binary>>), do: 2
  defp ws_size(<<0xE1, 0x9A, 0x80, _::binary>>), do: 3
  defp ws_size(<<0xE2, 0x80, c, _::binary>>) when c in 0x80..0x8A or c in [0xA8, 0xA9, 0xAF], do: 3
  defp ws_size(<<0xE2, 0x81, 0x9F, _::binary>>), do: 3
  defp ws_size(<<0xE3, 0x80, 0x80, _::binary>>), do: 3
  defp ws_size(<<0xEF, 0xBB, 0xBF, _::binary>>), do: 3
  defp ws_size(_), do: 0

  # {number of whitespace characters skipped, rest}
  defp skip_ws(s), do: skip_ws(s, 0)

  defp skip_ws(s, n) do
    case ws_size(s) do
      0 ->
        {n, s}

      size ->
        <<_::binary-size(^size), r::binary>> = s
        skip_ws(r, n + 1)
    end
  end

  @doc "`/^https?\\:\\/\\/schema\\.org\\/?$/` (`_getJSONLD` `@context` check)."
  @spec schema_org?(term) :: boolean
  def schema_org?(s), do: s in ["http://schema.org", "http://schema.org/", "https://schema.org", "https://schema.org/"]

  # ---------------------------------------------------------------------------------------------
  # Cold regexes
  # ---------------------------------------------------------------------------------------------

  # JS `\s` as a code-point class (for patterns compiled with "u") ...
  @ws_u ~S"[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]"
  # ... and as UTF-8 byte sequences, for byte-mode patterns that need ASCII-only `/i`
  @ws_b ~S"(?:[\t\n\x0B\f\r ]|\xC2\xA0|\xE1\x9A\x80|\xE2\x80[\x80-\x8A\xA8\xA9\xAF]|\xE2\x81\x9F|\xE3\x80\x80|\xEF\xBB\xBF)"
  # JS `.` (one UTF-16 code unit except \n \r U+2028 U+2029) in byte mode
  @dot_b ~S"(?:[^\n\r\x80-\xFF]|[\xC2-\xDF][\x80-\xBF]|\xE2(?!\x80[\xA8\xA9])[\x80-\xBF]{2}|[\xE0\xE1\xE3-\xEF][\x80-\xBF]{2})"
  @title_seps "|\\-–—\\\\/>»"

  @regexes [
    # `REGEXPS.videos`, the default `allowedVideoRegex`
    videos:
      {~S"\/\/(www\.)?((dailymotion|youtube|youtube-nocookie|player\.vimeo|v\.qq|bilibili|live" <>
         @dot_b <> ~S"bilibili)\.com|(archive|upload\.wikimedia)\.org|player\.twitch\.tv)", "i"},
    ad_words: {~S"^(ad(vertising|vertisement)?|pub(licité)?|werb(ung)?|广告|Реклама|Anuncio)\z", "iu"},
    loading_words: {~S"^((loading|正在加载|Загрузка|chargement|cargando)(…|\.\.\.)?)\z", "iu"},
    # `_getArticleTitle`: `\s[|\-–—\\/>»]\s`, `\s[\\/>»]\s` and `^[^|\-–—\\/>»]*[|\-–—\\/>»]`
    title_separator: {"#{@ws_u}[#{@title_seps}]#{@ws_u}", "u"},
    title_hierarchical_separator: {"#{@ws_u}[\\\\/>»]#{@ws_u}", "u"},
    title_first_part: {"^[^#{@title_seps}]*[#{@title_seps}]", "u"},
    # `_getArticleMetadata`
    meta_property:
      {"#{@ws_b}*(article|dc|dcterm|og|twitter)#{@ws_b}*:#{@ws_b}*" <>
         "(author|creator|description|published_time|title|site_name)#{@ws_b}*", "i"},
    meta_name:
      {"^#{@ws_b}*(?:(dc|dcterm|og|twitter|parsely|weibo:(article|webpage))#{@ws_b}*[-.:]#{@ws_b}*)?" <>
         "(author|creator|pub-date|description|title|site_name)#{@ws_b}*\\z", "i"},
    # `_getJSONLD`. The `^` and `$` of jsonLdArticleTypes bind to the first and last alternative only.
    jsonld_article_types:
      {"^Article|AdvertiserContentArticle|NewsArticle|AnalysisNewsArticle|AskPublicNewsArticle|" <>
         "BackgroundNewsArticle|OpinionNewsArticle|ReportageNewsArticle|ReviewNewsArticle|Report|" <>
         "SatiricalArticle|ScholarlyArticle|MedicalScholarlyArticle|SocialMediaPosting|BlogPosting|" <>
         "LiveBlogPosting|DiscussionForumPosting|TechArticle|APIReference\\z", ""},
    cdata: {"^#{@ws_u}*<!\\[CDATA\\[|\\]\\]>#{@ws_u}*\\z", "u"}
  ]

  @regex_names Keyword.keys(@regexes)

  @doc """
  A cold regex, compiled once per VM into `:persistent_term`. Names: #{Enum.map_join(@regex_names, ", ", &"`#{&1}`")}.
  JS translation: `$` is `\\z`, `\\s` is the JS class, `/i` without `u` is compiled in byte mode.
  """
  @spec regex(atom) :: Regex.t()
  def regex(name) when name in @regex_names do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> init()
      regexes -> regexes
    end
    |> Map.fetch!(name)
  end

  defp init do
    # Racing processes compile and store equal values; the last write wins.
    regexes = Map.new(@regexes, fn {name, {source, opts}} -> {name, Regex.compile!(source, opts)} end)
    :persistent_term.put(__MODULE__, regexes)
    regexes
  end

  @doc "The default `allowedVideoRegex` test, or `regex` when given. Prefilters on `//`."
  @spec video?(binary, Regex.t() | nil) :: boolean
  def video?(value, nil), do: :binary.match(value, "//") != :nomatch and Regex.match?(regex(:videos), value)
  def video?(value, regex), do: Regex.match?(regex, value)

  @doc """
  `adWords.test(text) || loadingWords.test(text)` (`_cleanConditionally`). Neither matches
  more than 13 UTF-16 code units, so callers can skip longer text without building it.
  """
  @spec ad_or_loading_words?(binary) :: boolean
  def ad_or_loading_words?(text) when byte_size(text) > 60, do: false

  def ad_or_loading_words?(text),
    do: Regex.match?(regex(:ad_words), text) or Regex.match?(regex(:loading_words), text)

  @doc "`@type.match(REGEXPS.jsonLdArticleTypes)` for a string `@type`."
  @spec jsonld_article_type?(binary) :: boolean
  def jsonld_article_type?(type), do: Regex.match?(regex(:jsonld_article_types), type)

  @doc """
  `_getArticleMetadata` for a `property` attribute: the first `propertyPattern` match,
  lower-cased with whitespace removed (e.g. `"og:title"`), or `nil`.
  """
  @spec meta_property_key(binary) :: binary | nil
  def meta_property_key(property) do
    case Regex.run(regex(:meta_property), property, capture: :first) do
      [match] -> match |> lower() |> remove_ws(<<>>)
      nil -> nil
    end
  end

  @doc """
  `_getArticleMetadata` for a `name` attribute: when `namePattern` matches, the name
  lower-cased, whitespace removed, dots turned into colons; otherwise `nil`.
  """
  @spec meta_name_key(binary) :: binary | nil
  def meta_name_key(name) do
    if Regex.match?(regex(:meta_name), name) do
      name |> lower() |> remove_ws(<<>>) |> :binary.replace(".", ":", [:global])
    end
  end

  # only ASCII letters and JS whitespace can be in a matched name besides `-.:_`
  defp remove_ws(<<>>, acc), do: acc

  defp remove_ws(s, acc) do
    case ws_size(s) do
      0 ->
        <<c, r::binary>> = s
        remove_ws(r, <<acc::binary, c>>)

      size ->
        <<_::binary-size(^size), r::binary>> = s
        remove_ws(r, acc)
    end
  end

  @doc "`content.replace(/^\\s*<!\\[CDATA\\[|\\]\\]>\\s*$/g, \"\")` (`_getJSONLD`)."
  @spec strip_cdata(binary) :: binary
  def strip_cdata(content) do
    if :binary.match(content, ["<![CDATA[", "]]>"]) == :nomatch,
      do: content,
      else: Regex.replace(regex(:cdata), content, "")
  end
end
