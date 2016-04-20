defmodule Readability do
  @moduledoc """
  """

  alias Readability.TitleFinder

  @default_options [retry_length: 250,
                    min_text_length: 25,
                    remove_unlikely_candidates: true,
                    weight_classes: true,
                    clean_conditionally: true,
                    remove_empty_nodes: true,
                    min_image_width: 130,
                    min_image_height: 80,
                    ignore_image_format: [],
                    blacklist: nil,
                    whitelist: nil
                   ]

  @regexes [unlikely_candidate: ~r/combx|comment|community|disqus|extra|foot|header|lightbox|modal|menu|meta|nav|remark|rss|shoutbox|sidebar|sponsor|ad-break|agegate|pagination|pager|popup/i,
            ok_maybe_its_a_candidate: ~r/and|article|body|column|main|shadow/i,
            positiveRe: ~r/article|body|content|entry|hentry|main|page|pagination|post|text|blog|story/i,
            negativeRe: ~r/combx|comment|com-|contact|foot|footer|footnote|link|masthead|media|meta|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|tool|utility|widget/i,
            div_to_p_elements: ~r/<(a|blockquote|dl|div|img|ol|p|pre|table|ul)/i,
            replaceBrsRe: ~r/(<br[^>]*>[ \n\r\t]*){2,}/i,
            replaceFontsRe: ~r/<(\/?)font[^>]*>/i,
            trimRe: ~r/^\s+|\s+$/,
            normalizeRe: ~r/\s{2,}/,
            killBreaksRe: ~r/(<br\s*\/?>(\s|&nbsp;?)*){1,}/,
            videoRe: ~r/http:\/\/(www\.)?(youtube|vimeo)\.com/i
           ]


  @type html_tree :: tuple | list

  def title(html) when is_binary(html), do: html |> parse |> title
  def title(html_tree), do: TitleFinder.title(html_tree)

  def parse(raw_html), do: Floki.parse(raw_html)

  def regexes, do: @regexes
  def default_options, do: @default_options
end
