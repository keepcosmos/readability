defmodule Readability.Candidate do
  defstruct html_tree: {}, score: 0

  alias Floki.SelectorTokenizer
  alias Floki.SelectorParser
  alias Floki.Selector

  @type html_tree :: tuple |list

  @doc """
  Check html_tree can be candidate.
  """

  @spec match?(html_tree) :: boolean

  def match?(html_tree) do
    candidates_selector
    |> Enum.any?(fn(selector) ->
         Selector.match?(html_tree, selector)
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
