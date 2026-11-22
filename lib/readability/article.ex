defmodule Readability.Article do
  @moduledoc """
  An article extracted by `Readability.article/2`.

  Fields mirror the result of Readability.js's `parse()`:

    * `:title` - the article title.
    * `:byline` - the author line, if one was found.
    * `:dir` - text direction (`"ltr"` or `"rtl"`), if the page declares one.
    * `:lang` - the page language (e.g. `"en"`), if declared.
    * `:content` - the cleaned article as an HTML string.
    * `:text_content` - the article's text, without markup.
    * `:length` - the length of `:text_content`, in characters (UTF-16 code units, like Readability.js).
    * `:excerpt` - a short description, from metadata or the first paragraph.
    * `:site_name` - the name of the site, if found.
    * `:published_time` - the publication time as found in the page's metadata
      (a string, not parsed), if any.
  """

  @type t :: %__MODULE__{
          title: String.t() | nil,
          byline: String.t() | nil,
          dir: String.t() | nil,
          lang: String.t() | nil,
          content: String.t(),
          text_content: String.t(),
          length: non_neg_integer(),
          excerpt: String.t() | nil,
          site_name: String.t() | nil,
          published_time: String.t() | nil
        }

  defstruct title: nil,
            byline: nil,
            dir: nil,
            lang: nil,
            content: "",
            text_content: "",
            length: 0,
            excerpt: nil,
            site_name: nil,
            published_time: nil
end
