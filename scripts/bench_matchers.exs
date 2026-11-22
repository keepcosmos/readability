# Class/id matcher micro-benchmark: Readability.Matchers vs PCRE and vs alternative matcher shapes.
#
#     mix run scripts/bench_matchers.exs
#
# Input: (class, id) of every element with a class or id in eight Readability.js test pages (the
# set design §1.5 used). Reports ns per element, median of several rounds.
defmodule BenchMatchers.Alt do
  # PCRE, compiled once at runtime and kept in :persistent_term (the best PCRE variant in design §1.5)
  @unlikely ~S"-ad-|ai2html|banner|breadcrumbs|combx|comment|community|cover-wrap|disqus|extra|footer|gdpr|header|legends|menu|related|remark|replies|rss|shoutbox|sidebar|skyscraper|social|sponsor|supplemental|ad-break|agegate|pagination|pager|popup|yom-remote"
  @maybe ~S"and|article|body|column|content|main|mathjax|shadow"
  @positive ~S"article|body|content|entry|hentry|h-entry|main|page|pagination|post|text|blog|story"
  @negative ~S"-ad-|hidden|^hid$| hid$| hid |^hid |banner|combx|comment|com-|contact|footer|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|widget"

  def init do
    re = fn src -> Regex.compile!(src, "i") end
    :persistent_term.put({__MODULE__, :re}, {re.(@unlikely), re.(@maybe), re.(@positive), re.(@negative)})

    words = &String.split(&1, "|")
    ac = {:binary.compile_pattern(words.(@unlikely)), :binary.compile_pattern(words.(@maybe))}
    :persistent_term.put({__MODULE__, :ac}, ac)
  end

  def re_unlikely_candidate?(class, id) do
    {u, m, _, _} = :persistent_term.get({__MODULE__, :re})
    s = (class || "") <> " " <> (id || "")
    Regex.match?(u, s) and not Regex.match?(m, s)
  end

  def re_class_weight(class, id), do: re_weight(class) + re_weight(id)
  defp re_weight(nil), do: 0
  defp re_weight(""), do: 0

  defp re_weight(s) do
    {_, _, p, n} = :persistent_term.get({__MODULE__, :re})
    w = if Regex.match?(n, s), do: -25, else: 0
    if Regex.match?(p, s), do: w + 25, else: w
  end

  # Aho-Corasick :binary.match over the ASCII-lower-cased string
  def ac_unlikely_candidate?(class, id) do
    {u, m} = :persistent_term.get({__MODULE__, :ac})
    s = Readability.Matchers.lower((class || "") <> " " <> (id || ""))
    :binary.match(s, u) != :nomatch and :binary.match(s, m) == :nomatch
  end

  # the prototype's two-function shape: scan/1 hands each suffix to at/1
  for {name, src} <- [unlikely: @unlikely, maybe: @maybe] do
    at = :"#{name}_at"
    scan = :"#{name}_scan"
    for w <- String.split(src, "|"), do: defp(unquote(at)(<<unquote(w), _::binary>>), do: true)
    defp unquote(at)(_), do: false
    defp unquote(scan)(<<>>), do: false
    defp unquote(scan)(<<_, r::binary>> = s), do: unquote(at)(s) or unquote(scan)(r)
  end

  def proto_unlikely_candidate?(class, id) do
    s = Readability.Matchers.lower((class || "") <> " " <> (id || ""))
    unlikely_scan(s) and not maybe_scan(s)
  end
end

defmodule BenchMatchers do
  @pages ~w(wikipedia-2 yahoo-2 pixnet nytimes-5 guardian-1 medium-1 aclu mozilla-1)
  @rounds 15

  def run do
    BenchMatchers.Alt.init()
    pairs = load()
    n = length(pairs)

    IO.puts(
      "#{n} elements with class or id in #{length(@pages)} pages; OTP #{System.otp_release()}, Elixir #{System.version()}"
    )

    IO.puts("ns/element, median of #{@rounds} rounds\n")

    alt = BenchMatchers.Alt
    m = Readability.Matchers

    rows = [
      {"unlikely_candidate?  Matchers (generated)", &m.unlikely_candidate?/2},
      {"unlikely_candidate?  :binary.match (AC)", &alt.ac_unlikely_candidate?/2},
      {"unlikely_candidate?  prototype scan/at", &alt.proto_unlikely_candidate?/2},
      {"unlikely_candidate?  Regex (:re)", &alt.re_unlikely_candidate?/2},
      {"class_weight         Matchers (generated)", &m.class_weight/2},
      {"class_weight         Regex (:re)", &alt.re_class_weight/2}
    ]

    # sanity: all variants agree on the input
    for {label, fun} <- rows, String.contains?(label, "unlikely") do
      true = Enum.all?(pairs, fn {c, i} -> fun.(c, i) == m.unlikely_candidate?(c, i) end)
    end

    true = Enum.all?(pairs, fn {c, i} -> alt.re_class_weight(c, i) == m.class_weight(c, i) end)

    for {label, fun} <- rows do
      ns = median(for _ <- 1..@rounds, do: time(pairs, fun)) * 1000 / n
      IO.puts(String.pad_trailing(label, 44) <> String.pad_leading(:erlang.float_to_binary(ns, decimals: 1), 8))
    end
  end

  defp time(pairs, fun) do
    {us, _} = :timer.tc(fn -> Enum.each(pairs, fn {c, i} -> fun.(c, i) end) end)
    us
  end

  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))

  defp load do
    for page <- @pages,
        html = File.read!("test/fixtures/readability_js/pages/#{page}/source.html"),
        node <- html |> LazyHTML.from_document() |> LazyHTML.to_tree() |> elements(),
        pair = class_id(node),
        pair != {nil, nil},
        do: pair
  end

  defp elements(nodes) do
    Enum.flat_map(nodes, fn
      {_tag, _attrs, children} = el -> [el | elements(children)]
      _ -> []
    end)
  end

  defp class_id({_tag, attrs, _}) do
    {List.keyfind(attrs, "class", 0) |> value(), List.keyfind(attrs, "id", 0) |> value()}
  end

  defp value(nil), do: nil
  defp value({_, v}), do: v
end

BenchMatchers.run()
