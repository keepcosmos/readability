defmodule Readability.Candidate do
  @moduledoc """
  """

  defstruct html_tree: {}, score: 0

  alias Floki.SelectorTokenizer
  alias Floki.SelectorParser
  alias Floki.Selector
  import Readability, only: [default_options: 0]

  @type html_tree :: tuple | list

  @doc """
  Check html_tree can be candidate.
  """

  @spec match?(html_tree) :: boolean

  def match?(html_tree) do
    candidates_selector
    |> Enum.any?(fn(selector) ->
         Selector.match?(html_tree, selector)
         && (html_tree |> Floki.text |> String.length) >= default_options[:min_text_length]
       end)
  end

  defp candidates_selector do
    ["p", "td"]
    |> Enum.map(fn(s) ->
         tokens = SelectorTokenizer.tokenize(s)
         SelectorParser.parse(tokens)
       end)
  end
end
