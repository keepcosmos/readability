defmodule Readability.URL do
  @moduledoc false
  # The part of the WHATWG URL Standard that Readability.js relies on: `new URL(input, base).href`
  # (`_fixRelativeUris`, `doc.baseURI`) and `new URL(input)` not throwing (`_isUrl`).
  #
  # Implemented: special schemes (http, https, ws, wss, ftp, file) and non-special ones, opaque
  # paths (`mailto:`, `data:`, `javascript:`), scheme-relative / path-absolute / path-relative /
  # query-only / fragment-only references, dot-segment removal (including `%2e`), `\` as `/` for
  # special schemes, userinfo, ports (default ports dropped), IPv6 hosts, Windows drive letters in
  # `file:` URLs, percent-encoding per the WHATWG percent-encode sets, input trimming and
  # tab/newline removal.
  #
  # Not implemented: IDNA and IPv4 parsing. Domains are percent-decoded and lower-cased (ASCII
  # letters only) but otherwise kept as written, see `parse_host/2`.
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
            absolute(uri, base)
        end

      # `new URL(uri, invalidBase)` always throws
      :error ->
        & &1
    end
  end

  defp absolute(uri, base) do
    case parse(uri, base) do
      {:ok, url} -> serialize(url)
      :error -> uri
    end
  end

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
  defp relative(input, base), do: relative(input, base, special?(base.scheme))

  defp relative(<<c1, c2, r::binary>>, base, true) when c1 in ~c"/\\" and c2 in ~c"/\\",
    do: authority(skip_slashes(r), %__MODULE__{scheme: base.scheme})

  defp relative(<<"//", r::binary>>, base, false), do: authority(r, %__MODULE__{scheme: base.scheme})

  defp relative(<<c, r::binary>>, base, special) when c == ?/ or (special and c == ?\\),
    do: {:ok, path_state(r, %{base | path: [], query: nil, fragment: nil})}

  defp relative(<<"?", r::binary>>, base, _special), do: {:ok, query_state(r, %{base | fragment: nil})}
  defp relative(<<"#", r::binary>>, base, _special), do: {:ok, %{base | fragment: encode(r, :fragment)}}
  defp relative(<<>>, base, _special), do: {:ok, %{base | fragment: nil}}

  defp relative(input, base, _special),
    do: {:ok, path_state(input, %{base | path: shorten(base.path, base.scheme), query: nil, fragment: nil})}

  # authority state + host state + port state; `input` is past the slashes
  defp authority(input, url) do
    special = special?(url.scheme)
    {auth, rest} = split_authority(input, special)

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

  # The authority ends at the first "/", "?" or "#" ("\\" too in special URLs).
  defp split_authority(input, special), do: split_authority(input, input, special, 0)

  defp split_authority(<<c, _::binary>>, input, special, i) when c in ~c"/?#" or (special and c == ?\\),
    do: {binary_part(input, 0, i), binary_part(input, i, byte_size(input) - i)}

  defp split_authority(<<_, r::binary>>, input, special, i), do: split_authority(r, input, special, i + 1)
  defp split_authority(<<>>, input, _special, _i), do: {input, <<>>}

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
  defp file_state(<<c1, c2, r::binary>>, url, _base) when c1 in ~c"/\\" and c2 in ~c"/\\", do: file_host(r, url)
  defp file_state(<<c, r::binary>>, url, base) when c in ~c"/\\", do: {:ok, path_state(r, file_slash(url, base, r))}
  defp file_state(input, url, nil), do: {:ok, path_state(input, url)}

  defp file_state(input, url, base) do
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
  end

  # "file:/path" against a file base keeps its host, and its drive letter unless the path has one.
  defp file_slash(url, nil, _rest), do: url

  defp file_slash(url, base, rest) do
    first = List.last(base.path)

    if normalized_drive_letter?(first) and not starts_with_drive_letter?(rest),
      do: %{url | host: base.host, path: [first]},
      else: %{url | host: base.host}
  end

  defp file_host(input, url) do
    {host, rest} = split_authority(input, true)

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

  # A domain is percent-decoded and its ASCII letters lower-cased, and that's all: unlike the
  # standard, non-ASCII names aren't converted to Punycode (IDNA) and numbers aren't parsed as
  # IPv4 addresses ("0x7f.1" stays as it is). Readability.js only needs relative links to resolve.
  defp parse_host(host, true) do
    if plain_host?(host) do
      host
    else
      host = host |> percent_decode() |> Readability.Text.lower()
      if host == "" or not String.valid?(host) or forbidden_domain?(host), do: fail()
      host
    end
  end

  # Lower-case letters, digits, "-" and "." only: nothing to do (the common case).
  defp plain_host?(<<c, r::binary>>) when c in ?a..?z or c in ?0..?9 or c == ?- or c == ?., do: plain_host?(r)
  defp plain_host?(<<_, _::binary>>), do: false
  defp plain_host?(<<>>), do: true

  defp forbidden_domain?(<<c, _::binary>>) when c in @forbidden_host or c < 0x20 or c == ?% or c == 0x7F, do: true
  defp forbidden_domain?(<<_, r::binary>>), do: forbidden_domain?(r)
  defp forbidden_domain?(<<>>), do: false

  defp percent_decode(s) do
    if String.contains?(s, "%"), do: pd(s, <<>>), else: s
  end

  defp pd(<<"%", a, b, r::binary>>, acc)
       when (a in ?0..?9 or a in ?a..?f or a in ?A..?F) and (b in ?0..?9 or b in ?a..?f or b in ?A..?F),
       do: pd(r, <<acc::binary, String.to_integer(<<a, b>>, 16)>>)

  defp pd(<<c, r::binary>>, acc), do: pd(r, <<acc::binary, c>>)
  defp pd(<<>>, acc), do: acc

  # OTP's strict parser follows the standard's IPv6 parser, except that it accepts zone IDs
  # ("fe80::1%eth0") and signs in an IPv4 part ("::1.+2.3.4"). No valid address is longer than
  # 45 bytes ("ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255").
  defp ipv6(s) do
    with true <- byte_size(s) <= 45,
         false <- String.contains?(s, ["%", "+", "-"]),
         {:ok, address} <- :inet.parse_ipv6strict_address(:erlang.binary_to_list(s)) do
      serialize_ipv6(Tuple.to_list(address))
    else
      _ -> fail()
    end
  end

  # The longest run (the first of equal ones) of at least two zero pieces becomes "::".
  defp serialize_ipv6(pieces) do
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
