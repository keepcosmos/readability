defmodule Readability.Document do
  @default_options  [retry_length: 250,
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

  def html do
    page
    |> String.replace(@regexes[:replaceBrsRe], "</p><p>")
    |> String.replace(@regexes[:replaceFontsRe], "<\1span>")
    |> Floki.find("html")
    |> Floki.filter_out(:comment)
  end

  def title do
    html |> Floki.find("title") |> Floki.text
  end

  def content do
    html
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
  end

  def page do
    {:ok, f} = File.read("test/features/nytimes.html")
    f
  end

  def default_options do
    @default_options
  end

  def regexes do
    @regexes
  end
end
