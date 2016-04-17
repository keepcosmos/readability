defmodule Readability.ContentFinder do
  @moduledoc """
  ContentFinder uses a variety of metrics for finding the content
  that is most likely to be the stuff a user wants to read.
  Then return it wrapped up in a div.
  """

  @regexes [ unlikelyCandidatesRe: ~r/combx|comment|community|disqus|extra|foot|header|lightbox|modal|menu|meta|nav|remark|rss|shoutbox|sidebar|sponsor|ad-break|agegate|pagination|pager|popup/i,
             okMaybeItsACandidateRe: ~r/and|article|body|column|main|shadow/i,
             positiveRe: ~r/article|body|content|entry|hentry|main|page|pagination|post|text|blog|story/i,
             negativeRe: ~r/combx|comment|com-|contact|foot|footer|footnote|link|masthead|media|meta|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|tool|utility|widget/i,
             divToPElementsRe: ~r/<(a|blockquote|dl|div|img|ol|p|pre|table|ul)/i,
             replaceBrsRe: ~r/(<br[^>]*>[ \n\r\t]*){2,}/i,
             replaceFontsRe: ~r/<(\/?)font[^>]*>/i,
             trimRe: ~r/^\s+|\s+$/,
             normalizeRe: ~r/\s{2,}/,
             killBreaksRe: ~r/(<br\s*\/?>(\s|&nbsp;?)*){1,}/,
             videoRe: ~r/http:\/\/(www\.)?(youtube|vimeo)\.com/i
           ]

  @type html_tree :: tuple | list

  @spec content(html_tree) :: html_tree

  def content(html_tree, options \\ []) do
    candidate = html_tree
                |> preapre_cadidates

    best_candidate = candidate
                     |> select_best_candidate

    candidate
    |> fix_relative_uris
  end

  defp preapre_cadidates(html_tree) do
    html_tree
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
    |> remove_unlikely_candidates
    |> transform_misused_divs_into_paragraphs
  end

  @doc """
  Remove unlikely tag nodes
  """

  @spec remove_unlikely_candidates(html_tree) :: html_tree

  def remove_unlikely_candidates(content) when is_binary(content), do: content
  def remove_unlikely_candidates([]), do: []
  def remove_unlikely_candidates([h|t]) do
    case remove_unlikely_candidates(h) do
      nil -> remove_unlikely_candidates(t)
      html_tree -> [html_tree|remove_unlikely_candidates(t)]
    end
  end
  def remove_unlikely_candidates({tag_name, attrs, inner_tree}) do
    cond do
      unlikely_candidate?(tag_name, attrs) -> nil
      true -> {tag_name, attrs, remove_unlikely_candidates(inner_tree)}
    end
  end
  defp unlikely_candidate?(tag_name, attrs) do
    idclass_str = attrs
                  |> Enum.filter_map(fn(attr) -> elem(attr, 0) =~ ~r/id|class/i end,
                                     fn(attr) -> elem(attr, 1) end)
                  |> Enum.join("")
    str = tag_name <> idclass_str
    str =~ @regexes[:unlikelyCandidatesRe] && !(str =~ @regexes[:okMaybeItsACandidateRe]) && tag_name != "html"
  end

  def transform_misused_divs_into_paragraphs(content) when is_binary(content), do: content
  def transform_misused_divs_into_paragraphs([]), do: []
  def transform_misused_divs_into_paragraphs([h|t]) do
    [transform_misused_divs_into_paragraphs(h)|transform_misused_divs_into_paragraphs(t)]
  end
  def transform_misused_divs_into_paragraphs({tag_name, attrs, inner_tree} = html_tree) do
    if misused_divs?(tag_name, inner_tree), do: tag_name = "p"
    {tag_name, attrs, transform_misused_divs_into_paragraphs(inner_tree)}
  end
  defp misused_divs?("div", inner_tree) do
    !(Floki.raw_html(inner_tree) =~ @regexes[:divToPElementsRe])
  end
  defp misused_divs?(_, _), do: false

  defp select_best_candidate(html_tree) do
    html_tree
  end

  defp fix_relative_uris(html_tree) do
    html_tree
  end
end
