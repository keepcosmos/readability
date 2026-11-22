defmodule Readability.URL do
  @moduledoc false
  # The part of the WHATWG URL Standard that Readability.js relies on: `new URL(input, base).href`
  # (`_fixRelativeUris`, `doc.baseURI`) and `new URL(input)` not throwing (`_isUrl`).
  #
  # Implemented: special schemes (http, https, ws, wss, ftp, file) and non-special ones, opaque
  # paths (`mailto:`, `data:`, `javascript:`), scheme-relative / path-absolute / path-relative /
  # query-only / fragment-only references, dot-segment removal (including `%2e`), `\` as `/` for
  # special schemes, userinfo, ports (default ports dropped), IPv4 (decimal, octal, hex, fewer
  # than four parts) and IPv6 hosts, percent-encoding per the WHATWG percent-encode sets, input
  # trimming and tab/newline removal.
  #
  # Approximated: IDNA. ASCII hosts are lower-cased and `xn--` labels are checked to decode;
  # non-ASCII hosts must be valid UTF-8 after percent-decoding, are NFKC-normalized, lower-cased,
  # stripped of the common UTS #46 "ignored" code points and Punycode-encoded, which agrees with
  # UTS #46 for ordinary names. Its mapping table is not implemented and of its validity criteria
  # only a subset that covers what `new URL` rejects in practice (see `check_label/1`).
  #
  # Errors are returned where `new URL` throws, so callers can keep the original value as
  # Readability.js does.

  import Bitwise

  @special %{"http" => 80, "https" => 443, "ws" => 80, "wss" => 443, "ftp" => 21, "file" => nil}

  # path is a reversed list of segments, or {:opaque, binary}
  defstruct scheme: nil, user: "", pass: "", host: nil, port: nil, path: [], query: nil, fragment: nil

  @type t :: %__MODULE__{}

  @doc "`new URL(input, base).href`. `base` is a string, a parsed URL or `nil` (no base)."
  @spec resolve(binary, binary | t | nil) :: {:ok, binary} | :error
  def resolve(input, base) do
    with {:ok, base} <- parse_base(base),
         {:ok, url} <- parse(input, base) do
      {:ok, serialize(url)}
    end
  end

  @doc "Parses an absolute URL, for use as a base in repeated `resolve/2` calls."
  @spec parse_base(binary | t | nil) :: {:ok, t | nil} | :error
  def parse_base(nil), do: {:ok, nil}
  def parse_base(%__MODULE__{} = url), do: {:ok, url}
  def parse_base(base) when is_binary(base), do: parse(base, nil)

  @doc "`_isUrl`: whether `new URL(str)` succeeds."
  @spec url?(binary) :: boolean
  def url?(str), do: match?({:ok, _}, parse(str, nil))

  @doc """
  `doc.baseURI` as JSDOMParser computes it: the `href` of the first `<base>` element resolved
  against the document URI, or the document URI when there is none or it does not resolve.
  """
  @spec base_uri(binary | nil, binary | nil) :: binary | nil
  def base_uri(document_uri, base_href) when base_href in [nil, ""], do: document_uri

  def base_uri(document_uri, base_href) do
    case resolve(base_href, document_uri) do
      {:ok, href} -> href
      :error -> document_uri
    end
  end

  @doc """
  `toAbsoluteURI` from `_fixRelativeUris`, with the base parsed once. Hash links are left alone
  when the base URI equals the document URI; values that fail to resolve are returned unchanged.
  """
  @spec absolutizer(binary | nil, binary | nil) :: (binary -> binary)
  def absolutizer(base_uri, document_uri) do
    keep_hash? = base_uri == document_uri

    case parse_base(base_uri) do
      {:ok, base} ->
        fn
          <<"#", _::binary>> = uri when keep_hash? ->
            uri

          uri ->
            case parse(uri, base) do
              {:ok, url} -> serialize(url)
              :error -> uri
            end
        end

      # `new URL(uri, invalidBase)` always throws
      :error ->
        & &1
    end
  end

  @doc "`toAbsoluteURI(uri)` without a prepared absolutizer."
  @spec to_absolute(binary, binary | nil, binary | nil) :: binary
  def to_absolute(uri, base_uri, document_uri), do: absolutizer(base_uri, document_uri).(uri)

  @doc """
  The `srcset` rewrite of `_fixRelativeUris`: `srcset.replace(srcsetUrl, (_, p1, p2, p3) =>
  toAbsoluteURI(p1) + (p2 || "") + p3)`. `absolutize` is a function from `absolutizer/2`.
  """
  @spec absolutize_srcset(binary, (binary -> binary)) :: binary
  def absolutize_srcset(srcset, absolutize) do
    Readability.Matchers.srcset_replace(srcset, fn p1, p2, p3 -> [absolutize.(p1), p2 | p3] end)
  end

  @doc "Readability.js removes links whose `href` starts with `javascript:` (case-sensitive)."
  @spec javascript?(binary) :: boolean
  def javascript?(<<"javascript:", _::binary>>), do: true
  def javascript?(_), do: false

  ## Parsing

  @spec parse(binary, t | nil) :: {:ok, t} | :error
  def parse(input, base) do
    input = input |> trim_c0() |> strip_tab_newline()

    try do
      case scheme(input, input, <<>>) do
        {scheme, rest} -> with_scheme(scheme, rest, base)
        nil -> no_scheme(input, base)
      end
    catch
      :url_error -> :error
    end
  end

  defp fail, do: throw(:url_error)

  defp trim_c0(s) do
    s = trim_leading(s)
    size = trim_trailing_size(s, byte_size(s))
    if size == byte_size(s), do: s, else: binary_part(s, 0, size)
  end

  defp trim_leading(<<c, r::binary>>) when c <= 0x20, do: trim_leading(r)
  defp trim_leading(s), do: s

  defp trim_trailing_size(_s, 0), do: 0

  defp trim_trailing_size(s, n) do
    if :binary.at(s, n - 1) <= 0x20, do: trim_trailing_size(s, n - 1), else: n
  end

  defp strip_tab_newline(s) do
    if tab_newline?(s), do: :binary.replace(s, ["\t", "\n", "\r"], "", [:global]), else: s
  end

  defp tab_newline?(<<c, _::binary>>) when c == ?\t or c == ?\n or c == ?\r, do: true
  defp tab_newline?(<<_, r::binary>>), do: tab_newline?(r)
  defp tab_newline?(<<>>), do: false

  # scheme start state + scheme state
  defp scheme(<<c, r::binary>>, input, <<>>) when c in ?a..?z or c in ?A..?Z,
    do: scheme(r, input, <<c ||| 0x20>>)

  defp scheme(_, _input, <<>>), do: nil

  defp scheme(<<c, r::binary>>, input, acc)
       when c in ?a..?z or c in ?0..?9 or c == ?+ or c == ?- or c == ?.,
       do: scheme(r, input, <<acc::binary, c>>)

  defp scheme(<<c, r::binary>>, input, acc) when c in ?A..?Z, do: scheme(r, input, <<acc::binary, c ||| 0x20>>)
  defp scheme(<<":", r::binary>>, _input, acc), do: {acc, r}
  defp scheme(_, _input, _acc), do: nil

  defp special?(scheme), do: is_map_key(@special, scheme)

  defp with_scheme("file", rest, base) do
    base = if base && base.scheme == "file", do: base
    file_state(rest, %__MODULE__{scheme: "file", host: ""}, base)
  end

  defp with_scheme(scheme, rest, base) do
    cond do
      special?(scheme) and base != nil and base.scheme == scheme ->
        relative(rest, base)

      special?(scheme) ->
        authority(skip_slashes(rest), %__MODULE__{scheme: scheme})

      true ->
        url = %__MODULE__{scheme: scheme}

        case rest do
          <<"//", r::binary>> -> authority(r, url)
          <<"/", r::binary>> -> {:ok, path_state(r, url)}
          _ -> {:ok, opaque_path(rest, url, <<>>)}
        end
    end
  end

  defp no_scheme(_input, nil), do: :error

  defp no_scheme(input, %__MODULE__{path: {:opaque, _}} = base) do
    case input do
      <<"#", r::binary>> -> {:ok, %{base | fragment: encode(r, :fragment)}}
      _ -> :error
    end
  end

  defp no_scheme(input, %__MODULE__{scheme: "file"} = base),
    do: file_state(input, %__MODULE__{scheme: "file", host: ""}, base)

  defp no_scheme(input, base), do: relative(input, base)

  defp skip_slashes(<<c, r::binary>>) when c == ?/ or c == ?\\, do: skip_slashes(r)
  defp skip_slashes(s), do: s

  # relative state + relative slash state
  defp relative(input, base) do
    special = special?(base.scheme)
    url = %__MODULE__{scheme: base.scheme}

    case input do
      <<c1, c2, r::binary>> when special and c1 in ~c"/\\" and c2 in ~c"/\\" ->
        authority(skip_slashes(r), url)

      <<"//", r::binary>> when not special ->
        authority(r, url)

      <<c, r::binary>> when c == ?/ or (special and c == ?\\) ->
        {:ok, path_state(r, %{base | path: [], query: nil, fragment: nil})}

      <<"?", r::binary>> ->
        {:ok, query_state(r, %{base | fragment: nil})}

      <<"#", r::binary>> ->
        {:ok, %{base | fragment: encode(r, :fragment)}}

      <<>> ->
        {:ok, %{base | fragment: nil}}

      _ ->
        {:ok, path_state(input, %{base | path: shorten(base.path, base.scheme), query: nil, fragment: nil})}
    end
  end

  # authority state + host state + port state; `input` is past the slashes
  defp authority(input, url) do
    special = special?(url.scheme)
    {auth, rest} = split_authority(input, special, 0)

    {url, hostport} =
      case last_at(auth, 0, nil) do
        nil ->
          {url, auth}

        at ->
          hostport = binary_part(auth, at + 1, byte_size(auth) - at - 1)
          if hostport == "", do: fail()
          {user, pass} = userinfo(binary_part(auth, 0, at))
          {%{url | user: user, pass: pass}, hostport}
      end

    {host, port} = split_port(hostport, false, 0)
    if host == "" and (special or port != nil), do: fail()

    url = %{url | host: parse_host(host, special), port: parse_port(port, url.scheme)}
    {:ok, path_start(rest, url)}
  end

  defp last_at(<<"@", r::binary>>, i, _at), do: last_at(r, i + 1, i)
  defp last_at(<<_, r::binary>>, i, at), do: last_at(r, i + 1, at)
  defp last_at(<<>>, _i, at), do: at

  defp split_authority(input, special, i) do
    case input do
      <<_::binary-size(^i), c, _::binary>> when c in ~c"/?#" or (special and c == ?\\) ->
        {binary_part(input, 0, i), binary_part(input, i, byte_size(input) - i)}

      <<_::binary-size(^i), _, _::binary>> ->
        split_authority(input, special, i + 1)

      _ ->
        {input, <<>>}
    end
  end

  defp userinfo(info) do
    case :binary.split(info, ":") do
      [user] -> {encode(user, :userinfo), ""}
      [user, pass] -> {encode(user, :userinfo), encode(pass, :userinfo)}
    end
  end

  defp split_port(s, in_brackets, i) do
    case s do
      <<_::binary-size(^i), ":", _::binary>> when not in_brackets ->
        {binary_part(s, 0, i), binary_part(s, i + 1, byte_size(s) - i - 1)}

      <<_::binary-size(^i), "[", _::binary>> ->
        split_port(s, true, i + 1)

      <<_::binary-size(^i), "]", _::binary>> ->
        split_port(s, false, i + 1)

      <<_::binary-size(^i), _, _::binary>> ->
        split_port(s, in_brackets, i + 1)

      _ ->
        {s, nil}
    end
  end

  defp parse_port(nil, _scheme), do: nil
  defp parse_port("", _scheme), do: nil

  defp parse_port(digits, scheme) do
    port = digits(digits, 0)
    if port == Map.get(@special, scheme), do: nil, else: port
  end

  defp digits(<<c, r::binary>>, n) when c in ?0..?9 do
    n = n * 10 + c - ?0
    if n > 65_535, do: fail(), else: digits(r, n)
  end

  defp digits(<<>>, n), do: n
  defp digits(_, _), do: fail()

  # path start state
  defp path_start(rest, url) do
    if special?(url.scheme) do
      case rest do
        <<c, r::binary>> when c == ?/ or c == ?\\ -> path_state(r, url)
        _ -> path_state(rest, url)
      end
    else
      case rest do
        <<"?", r::binary>> -> query_state(r, url)
        <<"#", r::binary>> -> %{url | fragment: encode(r, :fragment)}
        <<"/", r::binary>> -> path_state(r, url)
        <<>> -> url
      end
    end
  end

  # file state, file slash state, file host state
  defp file_state(input, url, base) do
    case input do
      <<c1, c2, r::binary>> when c1 in ~c"/\\" and c2 in ~c"/\\" ->
        file_host(r, url)

      <<c, r::binary>> when c in ~c"/\\" ->
        url =
          if base do
            url = %{url | host: base.host}

            case Enum.reverse(base.path) do
              [first | _] when is_binary(first) ->
                if not starts_with_drive_letter?(r) and normalized_drive_letter?(first),
                  do: %{url | path: [first]},
                  else: url

              _ ->
                url
            end
          else
            url
          end

        {:ok, path_state(r, url)}

      _ when base != nil ->
        url = %{url | host: base.host, path: base.path, query: base.query}

        case input do
          <<"?", r::binary>> ->
            {:ok, query_state(r, url)}

          <<"#", r::binary>> ->
            {:ok, %{url | fragment: encode(r, :fragment)}}

          <<>> ->
            {:ok, url}

          _ ->
            path = if starts_with_drive_letter?(input), do: [], else: shorten(base.path, "file")
            {:ok, path_state(input, %{url | path: path, query: nil})}
        end

      _ ->
        {:ok, path_state(input, url)}
    end
  end

  defp file_host(input, url) do
    {host, rest} = split_authority(input, true, 0)

    cond do
      drive_letter?(host) ->
        {:ok, path_state(input, url)}

      host == "" ->
        {:ok, path_start(rest, url)}

      true ->
        host = parse_host(host, true)
        host = if host == "localhost", do: "", else: host
        {:ok, path_start(rest, %{url | host: host})}
    end
  end

  defp drive_letter?(<<c, d>>) when (c in ?a..?z or c in ?A..?Z) and (d == ?: or d == ?|), do: true
  defp drive_letter?(_), do: false

  defp normalized_drive_letter?(<<c, ?:>>) when c in ?a..?z or c in ?A..?Z, do: true
  defp normalized_drive_letter?(_), do: false

  defp starts_with_drive_letter?(<<c, d>>), do: drive_letter?(<<c, d>>)

  defp starts_with_drive_letter?(<<c, d, e, _::binary>>) when e in ~c"/\\?#",
    do: drive_letter?(<<c, d>>)

  defp starts_with_drive_letter?(_), do: false

  defp shorten([], _scheme), do: []
  defp shorten([seg], "file") when byte_size(seg) == 2, do: if(normalized_drive_letter?(seg), do: [seg], else: [])
  defp shorten([_ | rest], _scheme), do: rest

  # path state: `url.path` is the reversed segment list built so far. A segment is scanned as
  # `seg` (the input from its first byte) and its length `i`; `enc?` tells whether a byte in it
  # needs percent-encoding, so the common segment is a sub-binary of the input.
  defp path_state(input, url), do: path_seg(input, input, 0, false, url, special?(url.scheme))

  defp path_seg(<<"/", r::binary>>, seg, i, enc?, url, special),
    do: path_seg(r, r, 0, false, end_segment(url, segment(seg, i, enc?), true), special)

  defp path_seg(<<"\\", r::binary>>, seg, i, enc?, url, true),
    do: path_seg(r, r, 0, false, end_segment(url, segment(seg, i, enc?), true), true)

  defp path_seg(<<"?", r::binary>>, seg, i, enc?, url, _special),
    do: query_state(r, end_segment(url, segment(seg, i, enc?), false))

  defp path_seg(<<"#", r::binary>>, seg, i, enc?, url, _special),
    do: %{end_segment(url, segment(seg, i, enc?), false) | fragment: encode(r, :fragment)}

  defp path_seg(<<>>, seg, i, enc?, url, _special), do: end_segment(url, segment(seg, i, enc?), false)

  # not in the path percent-encode set
  defp path_seg(<<c, r::binary>>, seg, i, enc?, url, special)
       when c > 0x20 and c < 0x7F and c != ?" and c != ?< and c != ?> and c != ?^ and c != ?` and c != ?{ and
              c != ?},
       do: path_seg(r, seg, i + 1, enc?, url, special)

  defp path_seg(<<_, r::binary>>, seg, i, _enc?, url, special), do: path_seg(r, seg, i + 1, true, url, special)

  defp segment(seg, i, false), do: binary_part(seg, 0, i)
  defp segment(seg, i, true), do: enc(binary_part(seg, 0, i), :path, <<>>)

  defp end_segment(url, buf, slash?) do
    cond do
      double_dot?(buf) ->
        path = shorten(url.path, url.scheme)
        %{url | path: if(slash?, do: path, else: ["" | path])}

      single_dot?(buf) ->
        if slash?, do: url, else: %{url | path: ["" | url.path]}

      url.scheme == "file" and url.path == [] and drive_letter?(buf) ->
        <<c, _>> = buf
        %{url | path: [<<c, ?:>>]}

      true ->
        %{url | path: [buf | url.path]}
    end
  end

  defp single_dot?("."), do: true
  defp single_dot?(<<"%2", e>>) when e == ?e or e == ?E, do: true
  defp single_dot?(_), do: false

  defp double_dot?(".."), do: true
  defp double_dot?(<<".%2", e>>) when e == ?e or e == ?E, do: true
  defp double_dot?(<<"%2", e, ".">>) when e == ?e or e == ?E, do: true
  defp double_dot?(<<"%2", e, "%2", f>>) when (e == ?e or e == ?E) and (f == ?e or f == ?E), do: true
  defp double_dot?(_), do: false

  defp lower(s), do: for(<<c <- s>>, into: <<>>, do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  # opaque path state (the trailing-space rule follows the current standard, as Node does)
  defp opaque_path(<<"?", r::binary>>, url, acc), do: query_state(r, %{url | path: {:opaque, acc}})

  defp opaque_path(<<"#", r::binary>>, url, acc),
    do: %{url | path: {:opaque, acc}, fragment: encode(r, :fragment)}

  defp opaque_path(<<" ", next, _::binary>> = s, url, acc) when next == ?? or next == ?# do
    <<_, r::binary>> = s
    opaque_path(r, url, <<acc::binary, "%20">>)
  end

  defp opaque_path(<<c, r::binary>>, url, acc) do
    if encode?(c, :c0),
      do: opaque_path(r, url, <<acc::binary, ?%, hex(c >>> 4), hex(c &&& 15)>>),
      else: opaque_path(r, url, <<acc::binary, c>>)
  end

  defp opaque_path(<<>>, url, acc), do: %{url | path: {:opaque, acc}}

  defp query_state(input, url) do
    set = if special?(url.scheme), do: :special_query, else: :query

    case :binary.split(input, "#") do
      [q] -> %{url | query: encode(q, set)}
      [q, f] -> %{url | query: encode(q, set), fragment: encode(f, :fragment)}
    end
  end

  ## Hosts

  @forbidden_host ~c"\0\t\n\r #/:<>?@[\\]^|"

  defp parse_host(<<"[", _::binary>> = host, _special) do
    size = byte_size(host)
    if :binary.last(host) != ?], do: fail()
    "[" <> ipv6(binary_part(host, 1, size - 2)) <> "]"
  end

  defp parse_host(host, false) do
    if String.contains?(host, Enum.map(@forbidden_host, &<<&1>>)), do: fail()
    encode(host, :c0)
  end

  defp parse_host(host, true) do
    if plain_host?(host, true, nil, nil), do: host, else: parse_domain(host)
  end

  # A host of lower-case letters, digits, "-" and "." with no "xn--" label and whose last label
  # starts with a letter (so it is not an IPv4 address) comes out of the host parser unchanged.
  # Arguments: at a label start?, first byte of the current label, of the last finished label.
  defp plain_host?(<<"xn--", _::binary>>, true, _cur, _last), do: false
  defp plain_host?(<<?., r::binary>>, _start, cur, _last), do: plain_host?(r, true, nil, cur)

  defp plain_host?(<<c, r::binary>>, start, cur, last) when c in ?a..?z or c in ?0..?9 or c == ?-,
    do: plain_host?(r, false, if(start, do: c, else: cur), last)

  defp plain_host?(<<>>, _start, cur, last), do: (cur || last) in ?a..?z
  defp plain_host?(_, _start, _cur, _last), do: false

  defp parse_domain(host) do
    domain = host |> percent_decode() |> domain_to_ascii()

    for <<c <- domain>>, c in @forbidden_host or c < 0x20 or c == ?% or c == 0x7F, do: fail()

    if ends_in_number?(domain), do: ipv4(domain), else: domain
  end

  defp percent_decode(s) do
    if String.contains?(s, "%"), do: pd(s, <<>>), else: s
  end

  defp pd(<<"%", a, b, r::binary>>, acc)
       when (a in ?0..?9 or a in ?a..?f or a in ?A..?F) and (b in ?0..?9 or b in ?a..?f or b in ?A..?F),
       do: pd(r, <<acc::binary, String.to_integer(<<a, b>>, 16)>>)

  defp pd(<<c, r::binary>>, acc), do: pd(r, <<acc::binary, c>>)
  defp pd(<<>>, acc), do: acc

  # UTS #46 ToASCII, approximated (see the module comment)
  defp domain_to_ascii(domain) do
    result =
      if ascii?(domain) do
        domain = lower(domain)
        for label <- :binary.split(domain, ".", [:global]), do: check_ace(label)
        domain
      else
        # "UTF-8 decode without BOM" turns invalid bytes into U+FFFD, which UTS #46 disallows
        if not String.valid?(domain), do: fail()

        domain
        |> String.replace(["。", "．", "｡"], ".")
        |> drop_ignored()
        |> :unicode.characters_to_nfkc_binary()
        |> String.downcase()
        |> :unicode.characters_to_nfc_binary()
        |> :binary.split(".", [:global])
        |> Enum.map_join(".", fn label ->
          if ascii?(label), do: check_ace(label), else: "xn--" <> punycode_encode(check_label(label))
        end)
      end

    if result == "", do: fail(), else: result
  end

  defp ascii?(s), do: for(<<c <- s>>, c >= 0x80, reduce: true, do: (_ -> false))

  defp check_ace(<<"xn--", encoded::binary>> = label) do
    case punycode_decode(encoded) do
      {:ok, decoded} when decoded != "" ->
        if ascii?(decoded), do: fail()
        check_label(decoded)
        label

      _ ->
        fail()
    end
  end

  defp check_ace(label), do: label

  # UTS #46 "ignored" code points (mapped to nothing) that can plausibly appear in a host: soft
  # hyphen, CGJ, ZWSP, word joiner and invisible operators, variation selectors, BOM, shorthand
  # format controls.
  defp drop_ignored(domain) do
    for <<cp::utf8 <- domain>>, not ignored?(cp), into: "", do: <<cp::utf8>>
  end

  defp ignored?(cp),
    do:
      cp in [0xAD, 0x34F, 0x200B, 0xFEFF] or cp in 0x2060..0x2064 or cp in 0xFE00..0xFE0F or
        cp in 0x1BCA0..0x1BCA3 or cp in 0xE0100..0xE01EF

  # A subset of the UTS #46 validity criteria (with WHATWG's flags), enough to reject what `new URL`
  # rejects in practice; the full mapping table is not implemented. A label fails when it starts with
  # a combining mark, or contains U+FFFD, a control, format (Cf), private-use or surrogate code point,
  # a line/paragraph separator or a noncharacter, or a ZWJ/ZWNJ outside the CONTEXTJ rules (RFC 5892
  # A.1/A.2, with the Arabic joining types of U+0620-06FF and U+0750-077F only). Unassigned code
  # points are accepted: OTP's Unicode version may be older than Node's.
  defp check_label(label) do
    cps = String.to_charlist(label)
    if match?({:mark, _}, category(hd(cps))), do: fail()
    check_cps(cps, [])
    label
  end

  defp check_cps([], _before), do: :ok

  defp check_cps([0x200D | rest], before) do
    if not virama?(before), do: fail()
    check_cps(rest, [0x200D | before])
  end

  defp check_cps([0x200C | rest], before) do
    if not (virama?(before) or (joins?(before, &joins_left?/1) and joins?(rest, &joins_right?/1))), do: fail()
    check_cps(rest, [0x200C | before])
  end

  defp check_cps([cp | rest], before) do
    if cp == 0xFFFD or cp in 0xFDD0..0xFDEF or (cp &&& 0xFFFE) == 0xFFFE, do: fail()

    case category(cp) do
      {:other, kind} when kind in [:control, :format, :private, :surrogate] -> fail()
      {:separator, kind} when kind in [:line, :paragraph] -> fail()
      _ -> check_cps(rest, [cp | before])
    end
  end

  defp category(cp), do: :unicode_util.lookup(cp).category
  defp virama?([cp | _]), do: :unicode_util.lookup(cp).ccc == 9
  defp virama?([]), do: false

  # The nearest code point that is not transparent (a non-spacing or enclosing mark) satisfies `fun`.
  defp joins?([cp | rest], fun) do
    case category(cp) do
      {:mark, kind} when kind in [:non_spacing, :enclosing] -> joins?(rest, fun)
      _ -> fun.(cp)
    end
  end

  defp joins?([], _fun), do: false

  # Joining type L or D (can join to the following letter)
  defp joins_left?(cp),
    do:
      cp in [0x620, 0x626, 0x628, 0x649, 0x64A, 0x66E, 0x66F, 0x6CC, 0x6CE, 0x6FF] or cp in 0x62A..0x62E or
        cp in 0x633..0x63F or cp in 0x641..0x647 or cp in 0x678..0x687 or cp in 0x69A..0x6BF or
        cp in 0x6C1..0x6C2 or cp in 0x6D0..0x6D1 or cp in 0x6FA..0x6FC or cp in 0x750..0x758 or
        cp in 0x75C..0x766

  # Joining type R or D (can join to the preceding letter)
  defp joins_right?(cp),
    do:
      cp in [0x620, 0x6D5, 0x6FF] or cp in 0x622..0x63F or cp in 0x641..0x64A or cp in 0x66E..0x66F or
        cp in 0x671..0x673 or cp in 0x675..0x6D3 or cp in 0x6EE..0x6EF or cp in 0x6FA..0x6FC or
        cp in 0x750..0x766

  defp ends_in_number?(domain) do
    parts = :binary.split(domain, ".", [:global])

    parts =
      case List.last(parts) do
        "" when length(parts) > 1 -> Enum.drop(parts, -1)
        _ -> parts
      end

    last = List.last(parts)

    cond do
      last == "" -> false
      for(<<c <- last>>, c not in ?0..?9, reduce: true, do: (_ -> false)) -> true
      ipv4_number(last) != :error -> true
      true -> false
    end
  end

  defp ipv4(domain) do
    parts = :binary.split(domain, ".", [:global])

    parts =
      case List.last(parts) do
        "" when length(parts) > 1 -> Enum.drop(parts, -1)
        _ -> parts
      end

    if length(parts) > 4, do: fail()
    numbers = Enum.map(parts, fn p -> with :error <- ipv4_number(p), do: fail() end)
    {init, [last]} = Enum.split(numbers, -1)
    if Enum.any?(init, &(&1 > 255)), do: fail()
    if last >= Integer.pow(256, 5 - length(numbers)), do: fail()

    n = Enum.reduce(Enum.with_index(init), last, fn {v, i}, acc -> acc + v * Integer.pow(256, 3 - i) end)
    Enum.join([n >>> 24, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255], ".")
  end

  defp ipv4_number(""), do: :error

  defp ipv4_number(s) do
    {digits, radix} =
      case s do
        <<"0", x, r::binary>> when x in ~c"xX" -> {r, 16}
        <<"0", r::binary>> when r != "" -> {r, 8}
        _ -> {s, 10}
      end

    cond do
      digits == "" -> 0
      valid_digits?(digits, radix) -> String.to_integer(digits, radix)
      true -> :error
    end
  end

  defp valid_digits?(s, 10), do: for(<<c <- s>>, c not in ?0..?9, reduce: true, do: (_ -> false))
  defp valid_digits?(s, 8), do: for(<<c <- s>>, c not in ?0..?7, reduce: true, do: (_ -> false))

  defp valid_digits?(s, 16),
    do: for(<<c <- s>>, not (c in ?0..?9 or c in ?a..?f or c in ?A..?F), reduce: true, do: (_ -> false))

  # IPv6 parser and serializer (WHATWG "IPv6 parser" / "IPv6 serializer")
  defp ipv6(s) do
    {pieces, compress} = ipv6_pieces(s, [], nil)
    n = length(pieces)

    pieces =
      cond do
        compress != nil ->
          {before, after_} = Enum.split(pieces, compress)
          before ++ List.duplicate(0, 8 - n) ++ after_

        n != 8 ->
          fail()

        true ->
          pieces
      end

    serialize_ipv6(pieces)
  end

  defp ipv6_pieces(<<"::", r::binary>>, [], nil), do: ipv6_after_compress(r, [], 0)
  defp ipv6_pieces(<<":", _::binary>>, [], nil), do: fail()
  defp ipv6_pieces(s, acc, compress), do: ipv6_piece(s, acc, compress)

  defp ipv6_after_compress(<<>>, acc, compress), do: {Enum.reverse(acc), compress}
  defp ipv6_after_compress(s, acc, compress), do: ipv6_piece(s, acc, compress)

  # `pieceIndex` of the spec: a "::" takes at least one piece.
  defp piece_index(acc, nil), do: length(acc)
  defp piece_index(acc, _compress), do: length(acc) + 1

  defp ipv6_piece(s, acc, compress) do
    if piece_index(acc, compress) >= 8, do: fail()
    {value, len, rest} = hex_piece(s, 0, 0)

    case rest do
      <<".", _::binary>> ->
        if len == 0 or piece_index(acc, compress) > 6, do: fail()
        start = byte_size(s) - byte_size(rest) - len
        [a, b, c, d] = ipv6_v4(binary_part(s, start, byte_size(s) - start))
        {Enum.reverse(acc, [a <<< 8 ||| b, c <<< 8 ||| d]), compress}

      <<"::", r::binary>> ->
        if compress != nil or len == 0 or length(acc) == 7, do: fail()
        acc = [value | acc]
        ipv6_after_compress(r, acc, length(acc))

      <<":", r::binary>> ->
        if len == 0 or r == "", do: fail()
        ipv6_piece(r, [value | acc], compress)

      <<>> ->
        if len == 0, do: fail()
        {Enum.reverse([value | acc]), compress}

      _ ->
        fail()
    end
  end

  defp hex_piece(<<c, r::binary>>, v, len) when len < 4 and (c in ?0..?9 or c in ?a..?f or c in ?A..?F),
    do: hex_piece(r, v * 16 + String.to_integer(<<c>>, 16), len + 1)

  defp hex_piece(rest, v, len), do: {v, len, rest}

  defp ipv6_v4(s) do
    parts = :binary.split(s, ".", [:global])
    if length(parts) != 4, do: fail()

    Enum.map(parts, fn p ->
      cond do
        p == "" or not valid_digits?(p, 10) -> fail()
        byte_size(p) > 1 and :binary.first(p) == ?0 -> fail()
        String.to_integer(p) > 255 -> fail()
        true -> String.to_integer(p)
      end
    end)
  end

  defp serialize_ipv6(pieces) do
    # longest run (first wins) of at least two zero pieces
    {start, len} =
      pieces
      |> Enum.with_index()
      |> Enum.chunk_by(fn {v, _} -> v == 0 end)
      |> Enum.filter(fn [{v, _} | _] = run -> v == 0 and length(run) > 1 end)
      |> Enum.reduce({nil, 0}, fn [{_, i} | _] = run, {s, l} ->
        if length(run) > l, do: {i, length(run)}, else: {s, l}
      end)

    hex = Enum.map(pieces, &String.downcase(Integer.to_string(&1, 16)))

    if start do
      {a, rest} = Enum.split(hex, start)
      b = Enum.drop(rest, len)
      Enum.join(a, ":") <> "::" <> Enum.join(b, ":")
    else
      Enum.join(hex, ":")
    end
  end

  ## Punycode (RFC 3492)

  @base 36
  @tmin 1
  @tmax 26
  @skew 38
  @damp 700
  @initial_bias 72
  @initial_n 128

  defp punycode_encode(label) do
    cps = String.to_charlist(label)
    basic = for c <- cps, c < 0x80, do: c
    b = length(basic)
    out = if b > 0, do: List.to_string(basic) <> "-", else: ""
    encode_loop(cps, @initial_n, 0, @initial_bias, b, b, out)
  end

  defp encode_loop(cps, n, delta, bias, h, b, out) do
    if h >= length(cps) do
      out
    else
      m = cps |> Enum.filter(&(&1 >= n)) |> Enum.min()
      delta = delta + (m - n) * (h + 1)

      {delta, bias, h, out} =
        Enum.reduce(cps, {delta, bias, h, out}, fn c, {delta, bias, h, out} ->
          cond do
            c < m ->
              {delta + 1, bias, h, out}

            c == m ->
              out = out <> encode_digits(delta, @base, bias)
              bias = adapt(delta, h + 1, h == b)
              {0, bias, h + 1, out}

            true ->
              {delta, bias, h, out}
          end
        end)

      encode_loop(cps, m + 1, delta + 1, bias, h, b, out)
    end
  end

  defp encode_digits(q, k, bias) do
    t = threshold(k, bias)

    if q < t do
      <<digit(q)>>
    else
      <<digit(t + rem(q - t, @base - t))>> <> encode_digits(div(q - t, @base - t), k + @base, bias)
    end
  end

  defp punycode_decode(input) do
    {basic, encoded} =
      case :binary.matches(input, "-") do
        [] ->
          {"", input}

        ms ->
          {pos, 1} = List.last(ms)
          {binary_part(input, 0, pos), binary_part(input, pos + 1, byte_size(input) - pos - 1)}
      end

    if ascii?(basic) do
      basic = String.to_charlist(basic)
      count = length(basic)
      decode_loop(encoded, {:lists.reverse(basic), [], count}, count, @initial_n, 0, @initial_bias)
    else
      :error
    end
  catch
    :url_error -> :error
  end

  # `out` is a zipper over the decoded code points: the ones before the insertion point (reversed),
  # the ones after it, and its position. Successive insertions are usually next to each other.
  defp decode_loop(<<>>, {left, right, _pos}, _count, _n, _i, _bias),
    do: {:ok, List.to_string(:lists.reverse(left, right))}

  defp decode_loop(input, out, count, n, i, bias) do
    {i2, rest} = decode_digits(input, i, 1, @base, bias)
    len = count + 1
    bias = adapt(i2 - i, len, i == 0)
    n = n + div(i2, len)
    i2 = rem(i2, len)
    if n > 0x10FFFF or n in 0xD800..0xDFFF, do: fail()
    {left, right, _} = move(out, i2)
    decode_loop(rest, {[n | left], right, i2 + 1}, len, n, i2 + 1, bias)
  end

  defp move({_, _, pos} = out, pos), do: out
  defp move({left, [c | right], pos}, to) when to > pos, do: move({[c | left], right, pos + 1}, to)
  defp move({[c | left], right, pos}, to), do: move({left, [c | right], pos - 1}, to)

  # Fails on 32-bit overflow like ada (WHATWG URL in Node), which also bounds the digits read.
  defp decode_digits(<<c, r::binary>>, i, w, k, bias) do
    d = undigit(c)
    i = i + d * w
    t = threshold(k, bias)
    w = w * (@base - t)

    cond do
      i > 0x7FFFFFFF -> fail()
      d < t -> {i, r}
      w > 0x7FFFFFFF -> fail()
      true -> decode_digits(r, i, w, k + @base, bias)
    end
  end

  defp decode_digits(<<>>, _i, _w, _k, _bias), do: fail()

  defp threshold(k, bias) do
    cond do
      k <= bias -> @tmin
      k >= bias + @tmax -> @tmax
      true -> k - bias
    end
  end

  defp adapt(delta, numpoints, first?) do
    delta = if first?, do: div(delta, @damp), else: div(delta, 2)
    delta = delta + div(delta, numpoints)
    adapt_loop(delta, 0)
  end

  defp adapt_loop(delta, k) when delta > div((@base - @tmin) * @tmax, 2),
    do: adapt_loop(div(delta, @base - @tmin), k + @base)

  defp adapt_loop(delta, k), do: k + div((@base - @tmin + 1) * delta, delta + @skew)

  defp digit(d) when d < 26, do: ?a + d
  defp digit(d), do: ?0 + d - 26

  defp undigit(c) when c in ?a..?z, do: c - ?a
  defp undigit(c) when c in ?A..?Z, do: c - ?A
  defp undigit(c) when c in ?0..?9, do: c - ?0 + 26
  defp undigit(_), do: fail()

  ## Percent-encoding

  # Bytes >= 0x80 are encoded by every set, so encoding byte-wise equals UTF-8 percent-encoding.
  @sets %{
    c0: ~c"",
    fragment: ~c" \"<>`",
    query: ~c" \"#<>",
    special_query: ~c" \"#<>'",
    path: ~c" \"#<>?^`{}",
    userinfo: ~c" \"#<>?^`{}/:;=@[\\]|"
  }

  for {set, extra} <- @sets, c <- 0..255 do
    if c < 0x20 or c > 0x7E or c in extra do
      defp encode?(unquote(c), unquote(set)), do: true
    end
  end

  defp encode?(_, _), do: false

  defp encode(s, set) do
    if needs_encoding?(s, set), do: enc(s, set, <<>>), else: s
  end

  defp needs_encoding?(<<c, r::binary>>, set), do: encode?(c, set) or needs_encoding?(r, set)
  defp needs_encoding?(<<>>, _set), do: false

  defp enc(<<c, r::binary>>, set, acc) do
    if encode?(c, set),
      do: enc(r, set, <<acc::binary, ?%, hex(c >>> 4), hex(c &&& 15)>>),
      else: enc(r, set, <<acc::binary, c>>)
  end

  defp enc(<<>>, _set, acc), do: acc

  defp hex(n) when n < 10, do: ?0 + n
  defp hex(n), do: ?A + n - 10

  ## Serializing

  @spec serialize(t) :: binary
  def serialize(%__MODULE__{} = url) do
    IO.iodata_to_binary([
      url.scheme,
      ":",
      authority_iodata(url),
      path_iodata(url),
      if(url.query, do: ["?", url.query], else: []),
      if(url.fragment, do: ["#", url.fragment], else: [])
    ])
  end

  defp authority_iodata(%{host: nil}), do: []

  defp authority_iodata(url) do
    userinfo =
      cond do
        url.user == "" and url.pass == "" -> []
        url.pass == "" -> [url.user, "@"]
        true -> [url.user, ":", url.pass, "@"]
      end

    ["//", userinfo, url.host, if(url.port, do: [":", Integer.to_string(url.port)], else: [])]
  end

  defp path_iodata(%{path: {:opaque, p}}), do: p
  defp path_iodata(%{path: []}), do: []

  defp path_iodata(%{path: path, host: host}) do
    segments = Enum.reverse(path)

    prefix =
      case segments do
        ["", _ | _] when host == nil -> "/."
        _ -> []
      end

    [prefix | Enum.map(segments, &["/", &1])]
  end
end
