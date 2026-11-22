defmodule Readability.Text do
  @moduledoc false
  # JavaScript string semantics as hand-written binary scanners (design section 1.4, section 4.2).
  #
  # * Whitespace is the JS `\s` class (also what `trim()` strips): TAB LF VT FF CR SPACE, U+00A0,
  #   U+1680, U+2000..U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF. U+0085 is NOT
  #   whitespace in JS (it is in PCRE with `u` and in `String.trim/1`).
  # * Lengths are UTF-16 code units: one per code point, two above U+FFFF.
  # * Commas are the nine code points of `REGEXPS.commas`: "," (counted as `commas`) and
  #   U+060C U+FE50 U+FE10 U+FE11 U+2E41 U+2E34 U+2E32 U+FF0C (counted as `xcommas`).
  #
  # Input is expected to be valid UTF-8 (LazyHTML only produces valid UTF-8). Invalid input never
  # raises; sequences are classified by their lead byte without validating continuation bytes.
  # `summary/1` and the other scanners count a stray continuation byte, or each byte of a sequence
  # truncated by the end of the string, as one non-whitespace unit; `length/1` counts lead bytes
  # (two for 4-byte leads) and ignores continuation bytes. Results on invalid input are therefore
  # approximate, but deterministic.
  #
  # Performance rule: every function that loops over a binary is private, self-recursive and starts
  # every clause with a binary match, so the match context is reused (see design section 1.4; check with
  # `ERL_COMPILER_OPTIONS=bin_opt_info`). Functions returning a part of their input return a
  # sub-binary of it, or the input itself when nothing changes.

  import Kernel, except: [length: 1]
  import Bitwise

  @typedoc """
  Text aggregate of a string, composable with `concat/2`:
  `{nonws, runs, lead, trail, commas, xcommas}` where `nonws` counts the UTF-16 units that are
  not whitespace, `runs` the maximal whitespace runs, `lead`/`trail` (0 or 1) whether the text
  starts/ends with whitespace, `commas` the "," and `xcommas` the other eight comma code points.
  """
  @type summary ::
          {non_neg_integer(), non_neg_integer(), 0 | 1, 0 | 1, non_neg_integer(), non_neg_integer()}

  # ---------------------------------------------------------------------------------------------
  # Character class table. Every scanner below is generated from it, so they cannot disagree.
  # kind: :ws | {:nonws, utf16_units, comma_kind} with comma_kind :none | :comma | :xcomma.
  # ---------------------------------------------------------------------------------------------
  r = Macro.var(:r, __MODULE__)
  c = Macro.var(:c, __MODULE__)

  classes = [
    {quote(do: <<unquote(c), unquote(r)::binary>>),
     quote(do: unquote(c) == 32 or (unquote(c) >= 9 and unquote(c) <= 13)), 1, :ws},
    {quote(do: <<?,, unquote(r)::binary>>), true, 1, {:nonws, 1, :comma}},
    {quote(do: <<unquote(c), unquote(r)::binary>>), quote(do: unquote(c) < 128), 1, {:nonws, 1, :none}},
    {quote(do: <<0xC2, 0xA0, unquote(r)::binary>>), true, 2, :ws},
    {quote(do: <<0xE2, 0x80, unquote(c), unquote(r)::binary>>),
     quote(
       do:
         (unquote(c) >= 0x80 and unquote(c) <= 0x8A) or unquote(c) == 0xA8 or unquote(c) == 0xA9 or
           unquote(c) == 0xAF
     ), 3, :ws},
    {quote(do: <<0xE1, 0x9A, 0x80, unquote(r)::binary>>), true, 3, :ws},
    {quote(do: <<0xE2, 0x81, 0x9F, unquote(r)::binary>>), true, 3, :ws},
    {quote(do: <<0xE3, 0x80, 0x80, unquote(r)::binary>>), true, 3, :ws},
    {quote(do: <<0xEF, 0xBB, 0xBF, unquote(r)::binary>>), true, 3, :ws},
    {quote(do: <<0xD8, 0x8C, unquote(r)::binary>>), true, 2, {:nonws, 1, :xcomma}},
    {quote(do: <<0xEF, 0xB9, 0x90, unquote(r)::binary>>), true, 3, {:nonws, 1, :xcomma}},
    {quote(do: <<0xEF, 0xB8, unquote(c), unquote(r)::binary>>), quote(do: unquote(c) == 0x90 or unquote(c) == 0x91), 3,
     {:nonws, 1, :xcomma}},
    {quote(do: <<0xE2, 0xB9, 0x81, unquote(r)::binary>>), true, 3, {:nonws, 1, :xcomma}},
    {quote(do: <<0xE2, 0xB8, unquote(c), unquote(r)::binary>>), quote(do: unquote(c) == 0xB4 or unquote(c) == 0xB2), 3,
     {:nonws, 1, :xcomma}},
    {quote(do: <<0xEF, 0xBC, 0x8C, unquote(r)::binary>>), true, 3, {:nonws, 1, :xcomma}},
    {quote(do: <<unquote(c), _, unquote(r)::binary>>), quote(do: unquote(c) >= 0xC0 and unquote(c) < 0xE0), 2,
     {:nonws, 1, :none}},
    {quote(do: <<unquote(c), _, _, unquote(r)::binary>>), quote(do: unquote(c) >= 0xE0 and unquote(c) < 0xF0), 3,
     {:nonws, 1, :none}},
    {quote(do: <<unquote(c), _, _, _, unquote(r)::binary>>), quote(do: unquote(c) >= 0xF0), 4, {:nonws, 2, :none}},
    # stray continuation byte or truncated sequence
    {quote(do: <<_, unquote(r)::binary>>), true, 1, {:nonws, 1, :none}}
  ]

  # The same pattern with the rest of the binary ignored, for clauses that stop scanning.
  stop = fn pat ->
    Macro.prewalk(pat, fn
      {:r, _, __MODULE__} -> {:_, [], nil}
      x -> x
    end)
  end

  # ---------------------------------------------------------------------------------------------
  # summary/1
  # ---------------------------------------------------------------------------------------------

  @doc """
  Summarizes a string (see `t:summary/0`). `normalized_length/1` of the summary equals JS
  `s.trim().replace(/\\s{2,}/g, " ").length`.

      iex> Readability.Text.summary(" a,  b ")
      {3, 3, 1, 1, 1, 0}
  """
  @spec summary(binary()) :: summary()
  def summary(bin) when is_binary(bin), do: s0(bin)

  # s0: nothing seen; sn: last char non-ws; sw: last char ws.
  # Fast path: runs of 8 spaces (indentation) in one step.
  defp sw(<<"        ", r::binary>>, nw, runs, lead, cm, xc), do: sw(r, nw, runs, lead, cm, xc)

  for {pat, guard, _size, kind} <- classes do
    case kind do
      :ws ->
        defp s0(unquote(pat)) when unquote(guard), do: sw(unquote(r), 0, 1, 1, 0, 0)

        defp sn(unquote(pat), nw, runs, lead, cm, xc) when unquote(guard),
          do: sw(unquote(r), nw, runs + 1, lead, cm, xc)

        defp sw(unquote(pat), nw, runs, lead, cm, xc) when unquote(guard), do: sw(unquote(r), nw, runs, lead, cm, xc)

      {:nonws, u, ck} ->
        {cm1, xc1} =
          case ck do
            :none -> {0, 0}
            :comma -> {1, 0}
            :xcomma -> {0, 1}
          end

        defp s0(unquote(pat)) when unquote(guard), do: sn(unquote(r), unquote(u), 0, 0, unquote(cm1), unquote(xc1))

        defp sn(unquote(pat), nw, runs, lead, cm, xc) when unquote(guard),
          do: sn(unquote(r), nw + unquote(u), runs, lead, cm + unquote(cm1), xc + unquote(xc1))

        defp sw(unquote(pat), nw, runs, lead, cm, xc) when unquote(guard),
          do: sn(unquote(r), nw + unquote(u), runs, lead, cm + unquote(cm1), xc + unquote(xc1))
    end
  end

  defp s0(<<>>), do: {0, 0, 0, 0, 0, 0}
  defp sn(<<>>, nw, runs, lead, cm, xc), do: {nw, runs, lead, 0, cm, xc}
  defp sw(<<>>, nw, runs, lead, cm, xc), do: {nw, runs, lead, 1, cm, xc}

  @doc "The summary of the empty string, the identity of `concat/2`."
  @spec empty() :: summary()
  def empty, do: {0, 0, 0, 0, 0, 0}

  @doc """
  Summary of the concatenation of the two strings summarized by `a` and `b`. Adjacent whitespace
  runs at the seam merge into one.
  """
  @spec concat(summary(), summary()) :: summary()
  def concat({0, 0, _, _, cm0, xc0}, {nw, runs, lead, trail, cm, xc}), do: {nw, runs, lead, trail, cm0 + cm, xc0 + xc}
  def concat({nw, runs, lead, trail, cm0, xc0}, {0, 0, _, _, cm, xc}), do: {nw, runs, lead, trail, cm0 + cm, xc0 + xc}

  def concat({nw0, runs0, lead, trail0, cm0, xc0}, {nw, runs, lead1, trail, cm, xc}),
    do: {nw0 + nw, runs0 + runs - min(trail0, lead1), lead, trail, cm0 + cm, xc0 + xc}

  @doc """
  JS `s.trim().replace(/\\s{2,}/g, " ").length` for a string or a summary: every interior
  whitespace run counts one unit, leading and trailing runs none.
  """
  @spec normalized_length(binary() | summary()) :: non_neg_integer()
  def normalized_length(bin) when is_binary(bin), do: normalized_length(summary(bin))
  def normalized_length({0, _, _, _, _, _}), do: 0
  def normalized_length({nw, runs, lead, trail, _, _}), do: nw + runs - lead - trail

  @doc "JS `str.split(/\\s+/).length`: number of whitespace runs + 1 (`\"\"` gives 1)."
  @spec word_count(binary()) :: pos_integer()
  def word_count(bin) when is_binary(bin), do: elem(summary(bin), 1) + 1

  # ---------------------------------------------------------------------------------------------
  # length/1
  # ---------------------------------------------------------------------------------------------

  @doc "JS `s.length`: UTF-16 code units."
  @spec length(binary()) :: non_neg_integer()
  def length(bin) when is_binary(bin), do: len(bin, 0)

  defp len(<<c, r::binary>>, n) when c < 0x80, do: len(r, n + 1)
  defp len(<<c, r::binary>>, n) when c < 0xC0, do: len(r, n)
  defp len(<<c, r::binary>>, n) when c < 0xF0, do: len(r, n + 1)
  defp len(<<_, r::binary>>, n), do: len(r, n + 2)
  defp len(<<>>, n), do: n

  # ---------------------------------------------------------------------------------------------
  # blank?/1, has_content?/1, hash_url?/1, whitespace?/1
  # ---------------------------------------------------------------------------------------------

  @doc "JS `!s.trim()` / `/^\\s*$/.test(s)`: the string is empty or only whitespace."
  @spec blank?(binary()) :: boolean()
  def blank?(bin) when is_binary(bin), do: bl(bin)

  # Fast path: runs of 8 spaces (indentation) in one step.
  defp bl(<<"        ", r::binary>>), do: bl(r)

  for {pat, guard, _size, :ws} <- classes do
    defp bl(unquote(pat)) when unquote(guard), do: bl(unquote(r))
  end

  defp bl(<<>>), do: true
  defp bl(<<_, _::binary>>), do: false

  @doc """
  JS `/\\S$/.test(s)` (`REGEXPS.hasContent`): the last character is not whitespace. Unlike PCRE,
  `$` does not match before a final newline, so `"foo\\n"` is `false`.
  """
  @spec has_content?(binary()) :: boolean()
  def has_content?(<<>>), do: false

  def has_content?(bin) when is_binary(bin) do
    size = byte_size(bin)

    case :binary.at(bin, size - 1) do
      c when c == 32 or (c >= 9 and c <= 13) -> false
      c when c < 0x80 -> true
      _ -> not ws_suffix?(bin, size)
    end
  end

  defp ws_suffix?(bin, size) when size >= 3 do
    case binary_part(bin, size - 3, 3) do
      <<_, 0xC2, 0xA0>> -> true
      tail -> ws3?(tail)
    end
  end

  defp ws_suffix?(bin, 2), do: bin == <<0xC2, 0xA0>>
  defp ws_suffix?(_bin, _size), do: false

  for {pat, guard, 3, :ws} <- classes do
    defp ws3?(unquote(stop.(pat))) when unquote(guard), do: true
  end

  defp ws3?(_), do: false

  @doc """
  JS `/^#.+/.test(s)` (`REGEXPS.hashUrl`): starts with `#` followed by a character that is not a
  line terminator (`\\n`, `\\r`, U+2028, U+2029; JS `.` without the `s` flag).
  """
  @spec hash_url?(binary() | nil) :: boolean()
  def hash_url?(<<?#, c, _::binary>>) when c == ?\n or c == ?\r, do: false
  def hash_url?(<<?#, 0xE2, 0x80, c, _::binary>>) when c == 0xA8 or c == 0xA9, do: false
  def hash_url?(<<?#, _, _::binary>>), do: true
  def hash_url?(_), do: false

  @doc "Whether the code point is JS whitespace."
  @spec whitespace_char?(non_neg_integer()) :: boolean()
  def whitespace_char?(c) when c == 32 or (c >= 9 and c <= 13), do: true
  def whitespace_char?(c) when c == 0xA0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A), do: true

  def whitespace_char?(c) when c == 0x2028 or c == 0x2029 or c == 0x202F or c == 0x205F or c == 0x3000 or c == 0xFEFF,
    do: true

  def whitespace_char?(_), do: false

  # ---------------------------------------------------------------------------------------------
  # trim/1
  # ---------------------------------------------------------------------------------------------

  defguardp graphic_ascii?(c) when c > 32 and c < 0x80

  @doc "JS `s.trim()`. Returns `bin` itself when there is nothing to trim, otherwise a sub-binary."
  @spec trim(binary()) :: binary()
  def trim(bin) when is_binary(bin) do
    if bin != <<>> and graphic_ascii?(:binary.first(bin)) and graphic_ascii?(:binary.last(bin)),
      do: bin,
      else: trim_slow(bin)
  end

  defp trim_slow(bin) do
    case tlead(bin, 0) do
      nil ->
        <<>>

      start ->
        stop = ttrail(binary_part(bin, start, byte_size(bin) - start), start, start)
        if start == 0 and stop == byte_size(bin), do: bin, else: binary_part(bin, start, stop - start)
    end
  end

  # tlead: skip leading whitespace, returns the offset of the first non-ws char or nil.
  # ttrail: returns the end offset of the last non-ws char.
  for {pat, guard, size, kind} <- classes do
    case kind do
      :ws ->
        defp tlead(unquote(pat), pos) when unquote(guard), do: tlead(unquote(r), pos + unquote(size))
        defp ttrail(unquote(pat), pos, last) when unquote(guard), do: ttrail(unquote(r), pos + unquote(size), last)

      {:nonws, _, _} ->
        defp tlead(unquote(stop.(pat)), pos) when unquote(guard), do: pos

        defp ttrail(unquote(pat), pos, _last) when unquote(guard),
          do: ttrail(unquote(r), pos + unquote(size), pos + unquote(size))
    end
  end

  defp tlead(<<>>, _pos), do: nil
  defp ttrail(<<>>, _pos, last), do: last

  # ---------------------------------------------------------------------------------------------
  # normalize/1, split_ws/1, remove_ws/1
  # ---------------------------------------------------------------------------------------------

  @doc """
  JS `s.replace(/\\s{2,}/g, " ")` (`REGEXPS.normalize`): every run of two or more whitespace
  characters becomes one space; a single whitespace character is kept as it is. Does not trim.
  Returns `bin` itself when nothing changes.
  """
  @spec normalize(binary()) :: binary()
  def normalize(bin) when is_binary(bin) do
    case nn(bin, bin, 0, 0, []) do
      [] -> bin
      iodata -> IO.iodata_to_binary(iodata)
    end
  end

  # nn: after a non-ws char (or at the start); n1: one ws char seen, starting at rs;
  # n2: two or more ws chars seen, starting at rs. cs = start of the pending unchanged chunk.
  for {pat, guard, size, kind} <- classes do
    case kind do
      :ws ->
        defp nn(unquote(pat), o, pos, cs, acc) when unquote(guard),
          do: n1(unquote(r), o, pos + unquote(size), cs, acc, pos)

        defp n1(unquote(pat), o, pos, cs, acc, rs) when unquote(guard),
          do: n2(unquote(r), o, pos + unquote(size), cs, acc, rs)

        defp n2(unquote(pat), o, pos, cs, acc, rs) when unquote(guard),
          do: n2(unquote(r), o, pos + unquote(size), cs, acc, rs)

      {:nonws, _, _} ->
        defp nn(unquote(pat), o, pos, cs, acc) when unquote(guard), do: nn(unquote(r), o, pos + unquote(size), cs, acc)

        defp n1(unquote(pat), o, pos, cs, acc, _rs) when unquote(guard),
          do: nn(unquote(r), o, pos + unquote(size), cs, acc)

        defp n2(unquote(pat), o, pos, cs, acc, rs) when unquote(guard),
          do: nn(unquote(r), o, pos + unquote(size), pos, [acc, binary_part(o, cs, rs - cs), ?\s])
    end
  end

  defp nn(<<>>, _o, _pos, 0, []), do: []
  defp nn(<<>>, o, pos, cs, acc), do: [acc, binary_part(o, cs, pos - cs)]
  defp n1(<<>>, _o, _pos, 0, [], _rs), do: []
  defp n1(<<>>, o, pos, cs, acc, _rs), do: [acc, binary_part(o, cs, pos - cs)]
  defp n2(<<>>, o, _pos, cs, acc, rs), do: [acc, binary_part(o, cs, rs - cs), ?\s]

  @doc """
  JS `s.split(/\\s+/)`: the parts between whitespace runs, including empty leading and trailing
  parts (`"" -> [""]`, `" a " -> ["", "a", ""]`).
  """
  @spec split_ws(binary()) :: [binary()]
  def split_ws(bin) when is_binary(bin), do: sp_n(bin, bin, 0, 0, [])

  # sp_n: inside a part that started at ps; sp_w: inside a whitespace run.
  for {pat, guard, size, kind} <- classes do
    case kind do
      :ws ->
        defp sp_n(unquote(pat), o, pos, ps, acc) when unquote(guard),
          do: sp_w(unquote(r), o, pos + unquote(size), [binary_part(o, ps, pos - ps) | acc])

        defp sp_w(unquote(pat), o, pos, acc) when unquote(guard), do: sp_w(unquote(r), o, pos + unquote(size), acc)

      {:nonws, _, _} ->
        defp sp_n(unquote(pat), o, pos, ps, acc) when unquote(guard),
          do: sp_n(unquote(r), o, pos + unquote(size), ps, acc)

        defp sp_w(unquote(pat), o, pos, acc) when unquote(guard),
          do: sp_n(unquote(r), o, pos + unquote(size), pos, acc)
    end
  end

  defp sp_n(<<>>, o, pos, ps, acc), do: :lists.reverse(acc, [binary_part(o, ps, pos - ps)])
  defp sp_w(<<>>, _o, _pos, acc), do: :lists.reverse(acc, [<<>>])

  @doc "JS `s.replace(/\\s/g, \"\")`. Returns `bin` itself when it has no whitespace."
  @spec remove_ws(binary()) :: binary()
  def remove_ws(bin) when is_binary(bin) do
    case rw(bin, bin, 0, 0, []) do
      [] -> bin
      iodata -> IO.iodata_to_binary(iodata)
    end
  end

  for {pat, guard, size, kind} <- classes do
    case kind do
      :ws ->
        defp rw(unquote(pat), o, pos, cs, acc) when unquote(guard),
          do: rw(unquote(r), o, pos + unquote(size), pos + unquote(size), [acc | binary_part(o, cs, pos - cs)])

      {:nonws, _, _} ->
        defp rw(unquote(pat), o, pos, cs, acc) when unquote(guard), do: rw(unquote(r), o, pos + unquote(size), cs, acc)
    end
  end

  defp rw(<<>>, _o, _pos, 0, []), do: []
  defp rw(<<>>, o, pos, cs, acc), do: [acc | binary_part(o, cs, pos - cs)]

  # ---------------------------------------------------------------------------------------------
  # lower/1
  # ---------------------------------------------------------------------------------------------

  @doc """
  ASCII lower-casing (what a JS `/i` regex without `u` folds). Returns `bin` itself when it has no
  upper-case ASCII letter.
  """
  @spec lower(binary()) :: binary()
  def lower(bin) when is_binary(bin) do
    case up(bin, 0) do
      nil -> bin
      pos -> lo(binary_part(bin, pos, byte_size(bin) - pos), binary_part(bin, 0, pos))
    end
  end

  defp up(<<c, _::binary>>, pos) when c >= ?A and c <= ?Z, do: pos
  defp up(<<_, r::binary>>, pos), do: up(r, pos + 1)
  defp up(<<>>, _pos), do: nil

  defp lo(<<c, r::binary>>, acc) when c >= ?A and c <= ?Z, do: lo(r, <<acc::binary, c + 32>>)
  defp lo(<<c, r::binary>>, acc), do: lo(r, <<acc::binary, c>>)
  defp lo(<<>>, acc), do: acc

  # ---------------------------------------------------------------------------------------------
  # text_similarity/2
  # ---------------------------------------------------------------------------------------------

  @doc """
  Port of `_textSimilarity(textA, textB)`: 1 minus the share of `textB`'s tokens (by joined length)
  that do not occur in `textA`. Tokens come from `toLowerCase()` and a split on ASCII `\\W+`, so
  every non-ASCII character is a separator. Returns `0.0` when either text has no token.
  """
  @spec text_similarity(binary(), binary()) :: float()
  def text_similarity(a, b) when is_binary(a) and is_binary(b) do
    tokens_a = tokenize(String.downcase(a))
    tokens_b = tokenize(String.downcase(b))

    if tokens_a == [] or tokens_b == [] do
      0.0
    else
      set_a = MapSet.new(tokens_a)
      uniq_b = Enum.reject(tokens_b, &MapSet.member?(set_a, &1))
      1 - joined_length(uniq_b) / joined_length(tokens_b)
    end
  end

  # Tokens are ASCII-only, so byte size equals UTF-16 length.
  defp joined_length([]), do: 0
  defp joined_length(tokens), do: Enum.reduce(tokens, -1, &(byte_size(&1) + &2 + 1))

  defp tokenize(bin), do: tok_sep(bin, bin, 0, [])

  # tok_sep: in a separator run; tok_w: in a word that started at ws.
  defp tok_sep(<<c, r::binary>>, o, pos, acc) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
    do: tok_w(r, o, pos + 1, pos, acc)

  defp tok_sep(<<_, r::binary>>, o, pos, acc), do: tok_sep(r, o, pos + 1, acc)
  defp tok_sep(<<>>, _o, _pos, acc), do: :lists.reverse(acc)

  defp tok_w(<<c, r::binary>>, o, pos, ws, acc) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
    do: tok_w(r, o, pos + 1, ws, acc)

  defp tok_w(<<_, r::binary>>, o, pos, ws, acc), do: tok_sep(r, o, pos + 1, [binary_part(o, ws, pos - ws) | acc])
  defp tok_w(<<>>, o, pos, ws, acc), do: :lists.reverse(acc, [binary_part(o, ws, pos - ws)])

  # ---------------------------------------------------------------------------------------------
  # unescape_html_entities/1
  # ---------------------------------------------------------------------------------------------

  @doc """
  Port of `_unescapeHtmlEntities(str)`: first `&quot; &amp; &apos; &lt; &gt;` (case-sensitive),
  then numeric references `&#NNN;` / `&#xHHH;` (case-insensitive `x` and hex digits). Code point
  0, values above U+10FFFF and surrogates become U+FFFD. Two passes, each left to right without
  rescanning its own output, exactly like the two chained `replace` calls (`"&amp;#65;"` gives
  `"A"`). `nil` and `""` are returned unchanged.
  """
  @spec unescape_html_entities(binary() | nil) :: binary() | nil
  def unescape_html_entities(nil), do: nil
  def unescape_html_entities(<<>>), do: <<>>

  def unescape_html_entities(str) when is_binary(str) do
    case :binary.match(str, "&") do
      :nomatch -> str
      _ -> str |> named_entities() |> numeric_entities()
    end
  end

  defp named_entities(str), do: ne(str, str, 0, 0, [])

  for {name, char} <- [{"quot", ?"}, {"amp", ?&}, {"apos", ?'}, {"lt", ?<}, {"gt", ?>}] do
    len = byte_size(name) + 2

    defp ne(<<?&, unquote(name), ?;, r::binary>>, o, pos, cs, acc),
      do: ne(r, o, pos + unquote(len), pos + unquote(len), [acc, binary_part(o, cs, pos - cs), unquote(char)])
  end

  defp ne(<<_, r::binary>>, o, pos, cs, acc), do: ne(r, o, pos + 1, cs, acc)
  defp ne(<<>>, o, _pos, 0, []), do: o
  defp ne(<<>>, o, pos, cs, acc), do: IO.iodata_to_binary([acc, binary_part(o, cs, pos - cs)])

  defp numeric_entities(str), do: nume(str, str, 0, 0, [])

  defp nume(<<?&, ?#, x, r::binary>>, o, pos, cs, acc) when x == ?x or x == ?X do
    case hex(r, 0, 0) do
      {n, digits} -> num_ref(n, o, pos, pos + 3 + digits + 1, cs, acc)
      nil -> nume(r, o, pos + 3, cs, acc)
    end
  end

  defp nume(<<?&, ?#, r::binary>>, o, pos, cs, acc) do
    case dec(r, 0, 0) do
      {n, digits} -> num_ref(n, o, pos, pos + 2 + digits + 1, cs, acc)
      nil -> nume(r, o, pos + 2, cs, acc)
    end
  end

  defp nume(<<_, r::binary>>, o, pos, cs, acc), do: nume(r, o, pos + 1, cs, acc)
  defp nume(<<>>, o, _pos, 0, []), do: o
  defp nume(<<>>, o, pos, cs, acc), do: IO.iodata_to_binary([acc, binary_part(o, cs, pos - cs)])

  defp num_ref(n, o, pos, next, cs, acc) do
    n = if n == 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF), do: 0xFFFD, else: n
    rest = binary_part(o, next, byte_size(o) - next)
    nume(rest, o, next, next, [acc, binary_part(o, cs, pos - cs), <<n::utf8>>])
  end

  # Returns {value, digit_count} when at least one digit is followed by ";", else nil. The value
  # saturates at 0x110000 (any value above U+10FFFF becomes U+FFFD), so it stays a small integer.
  @over 0x110000
  defp hex(<<c, r::binary>>, n, d) when c in ?0..?9, do: hex(r, sat((n <<< 4) + c - ?0), d + 1)
  defp hex(<<c, r::binary>>, n, d) when c in ?a..?f, do: hex(r, sat((n <<< 4) + c - ?a + 10), d + 1)
  defp hex(<<c, r::binary>>, n, d) when c in ?A..?F, do: hex(r, sat((n <<< 4) + c - ?A + 10), d + 1)
  defp hex(<<?;, _::binary>>, n, d) when d > 0, do: {n, d}
  defp hex(_, _n, _d), do: nil

  defp dec(<<c, r::binary>>, n, d) when c in ?0..?9, do: dec(r, sat(n * 10 + c - ?0), d + 1)
  defp dec(<<?;, _::binary>>, n, d) when d > 0, do: {n, d}
  defp dec(_, _n, _d), do: nil

  defp sat(n) when n > @over, do: @over
  defp sat(n), do: n
end
