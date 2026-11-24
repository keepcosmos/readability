defmodule Readability.Charset do
  @moduledoc false
  # The character encoding a document declares, for input that isn't valid UTF-8. Readability.js
  # always gets a decoded DOM; here the bytes are taken as UTF-8, so a page in another encoding
  # comes out as replacement characters. Such a page is rejected instead of extracted as garbage.
  #
  # The declaration is the first `<meta charset>` or `<meta http-equiv="content-type"
  # content="...; charset=...">` that names a known encoding, in document order, like the HTML
  # standard's prescan (which reads only the first 1024 bytes). Labels are compared after
  # trimming and lowercasing; the UTF-16 ones count as UTF-8, because the prescan does the same.
  #
  # Pages often declare one encoding and are in another, so the declaration alone doesn't decide:
  # a page is rejected only when its malformed bytes outnumber its well-formed non-ASCII
  # characters (`mostly_invalid?/1`). A page in UTF-8 with a few stray bytes has many more of the
  # latter; a page in Shift_JIS, GBK or Latin-1 has hardly any.

  # From https://encoding.spec.whatwg.org/encodings.json: the labels of UTF-8 and UTF-16 (read as
  # UTF-8 by the prescan), and of every other encoding. Other labels aren't encodings and are skipped.
  @utf8_labels ~w(csunicode iso-10646-ucs-2 ucs-2 unicode unicode-1-1-utf-8 unicode11utf8 unicode20utf8 unicodefeff
                  unicodefffe utf-16 utf-16be utf-16le utf-8 utf8 x-unicode20utf8)

  @other_labels ~w(866 ansi_x3.4-1968 arabic ascii asmo-708 big5 big5-hkscs chinese cn-big5 cp1250 cp1251 cp1252
                   cp1253 cp1254 cp1255 cp1256 cp1257 cp1258 cp819 cp866 csbig5 cseuckr cseucpkdfmtjapanese csgb2312
                   csibm866 csiso2022jp csiso2022kr csiso58gb231280 csiso88596e csiso88596i csiso88598e csiso88598i
                   csisolatin1 csisolatin2 csisolatin3 csisolatin4 csisolatin5 csisolatin6 csisolatin9
                   csisolatinarabic csisolatincyrillic csisolatingreek csisolatinhebrew cskoi8r csksc56011987
                   csmacintosh csshiftjis cyrillic dos-874 ecma-114 ecma-118 elot_928 euc-jp euc-kr gb18030 gb2312
                   gb_2312 gb_2312-80 gbk greek greek8 hebrew hz-gb-2312 ibm819 ibm866 iso-2022-cn iso-2022-cn-ext
                   iso-2022-jp iso-2022-kr iso-8859-1 iso-8859-10 iso-8859-11 iso-8859-13 iso-8859-14 iso-8859-15
                   iso-8859-16 iso-8859-2 iso-8859-3 iso-8859-4 iso-8859-5 iso-8859-6 iso-8859-6-e iso-8859-6-i
                   iso-8859-7 iso-8859-8 iso-8859-8-e iso-8859-8-i iso-8859-9 iso-ir-100 iso-ir-101 iso-ir-109
                   iso-ir-110 iso-ir-126 iso-ir-127 iso-ir-138 iso-ir-144 iso-ir-148 iso-ir-149 iso-ir-157 iso-ir-58
                   iso8859-1 iso8859-10 iso8859-11 iso8859-13 iso8859-14 iso8859-15 iso8859-2 iso8859-3 iso8859-4
                   iso8859-5 iso8859-6 iso8859-7 iso8859-8 iso8859-9 iso88591 iso885910 iso885911 iso885913 iso885914
                   iso885915 iso88592 iso88593 iso88594 iso88595 iso88596 iso88597 iso88598 iso88599 iso_8859-1
                   iso_8859-15 iso_8859-1:1987 iso_8859-2 iso_8859-2:1987 iso_8859-3 iso_8859-3:1988 iso_8859-4
                   iso_8859-4:1988 iso_8859-5 iso_8859-5:1988 iso_8859-6 iso_8859-6:1987 iso_8859-7 iso_8859-7:1987
                   iso_8859-8 iso_8859-8:1988 iso_8859-9 iso_8859-9:1989 koi koi8 koi8-r koi8-ru koi8-u koi8_r korean
                   ks_c_5601-1987 ks_c_5601-1989 ksc5601 ksc_5601 l1 l2 l3 l4 l5 l6 l9 latin1 latin2 latin3 latin4
                   latin5 latin6 logical mac macintosh ms932 ms_kanji replacement shift-jis shift_jis sjis
                   sun_eu_greek tis-620 us-ascii visual windows-1250 windows-1251 windows-1252 windows-1253
                   windows-1254 windows-1255 windows-1256 windows-1257 windows-1258 windows-31j windows-874
                   windows-949 x-cp1250 x-cp1251 x-cp1252 x-cp1253 x-cp1254 x-cp1255 x-cp1256 x-cp1257 x-cp1258
                   x-euc-jp x-gbk x-mac-cyrillic x-mac-roman x-mac-ukrainian x-sjis x-user-defined x-x-big5)

  @doc "The declared encoding's label when it isn't UTF-8, else `nil` (also when none is declared)."
  @spec unsupported(LazyHTML.t()) :: String.t() | nil
  def unsupported(lazy) do
    label =
      lazy
      |> LazyHTML.query("meta[charset], meta[http-equiv]")
      |> LazyHTML.attributes()
      |> Enum.find_value(&declared/1)

    if label in @other_labels, do: label
  end

  @doc """
  Whether the text and attribute values of `LazyHTML.to_tree/1` output (comments aside) have more
  bytes that aren't part of well-formed UTF-8 than non-ASCII characters that are.
  """
  @spec mostly_invalid?(list()) :: boolean()
  def mostly_invalid?(tree) do
    {valid, invalid} = count_list(tree, {0, 0})
    invalid > valid
  end

  defp count_list([], acc), do: acc
  defp count_list([text | rest], acc) when is_binary(text), do: count_list(rest, count(text, acc))
  defp count_list([{:comment, _} | rest], acc), do: count_list(rest, acc)

  defp count_list([{_tag, attrs, children} | rest], acc) do
    acc = Enum.reduce(attrs, acc, fn {_name, value}, acc -> count(value, acc) end)
    count_list(rest, count_list(children, acc))
  end

  defp count(<<c, rest::binary>>, acc) when c < 0x80, do: count(rest, acc)
  defp count(<<c::utf8, rest::binary>>, {valid, invalid}) when c >= 0x80, do: count(rest, {valid + 1, invalid})
  defp count(<<_, rest::binary>>, {valid, invalid}), do: count(rest, {valid, invalid + 1})
  defp count(<<>>, acc), do: acc

  defp declared(attrs) do
    case List.keyfind(attrs, "charset", 0) do
      {_, value} -> value |> normalize() |> known()
      nil -> if content_type?(attrs), do: attrs |> List.keyfind("content", 0) |> from_content() |> known()
    end
  end

  defp known(label) when label in @utf8_labels or label in @other_labels, do: label
  defp known(_label), do: nil

  defp content_type?(attrs) do
    case List.keyfind(attrs, "http-equiv", 0) do
      {_, value} -> normalize(value) == "content-type"
      nil -> false
    end
  end

  # "Extracting a character encoding from a meta element", simplified: the value after
  # `charset=`, quoted or up to a `;` or whitespace.
  defp from_content({_, content}) do
    content = normalize(content)

    with [_, rest] <- :binary.split(content, "charset"),
         "=" <> rest <- String.trim_leading(rest) do
      rest |> String.trim_leading() |> unquote_label()
    else
      _ -> nil
    end
  end

  defp from_content(nil), do: nil

  defp unquote_label(<<quote, rest::binary>>) when quote in [?", ?'] do
    case :binary.split(rest, <<quote>>) do
      [label, _] -> String.trim(label)
      [_unterminated] -> nil
    end
  end

  defp unquote_label(value), do: value |> String.split([";", " ", "\t", "\n", "\f", "\r"]) |> hd()

  defp normalize(value), do: value |> String.replace_invalid() |> String.trim() |> String.downcase(:ascii)
end
