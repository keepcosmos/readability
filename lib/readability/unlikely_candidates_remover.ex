defmodule Readability.UnlikelyCandidatesRemover do
  @moduledoc """
  Remove unlikely candidates
  """

  @type html_tree :: tuple | list

  @doc """
  Remove unlikely candidates
  """

  @spec remove(html_tree) :: html_tree

  def remove(content) when is_binary(content), do: content
  def remove([]), do: []
  def remove([h|t]) do
    case remove(h) do
      nil -> remove(t)
      html_tree -> [html_tree|remove(t)]
    end
  end
  def remove({tag, attrs, inner_tree}) do
    if unlikely_candidate?(tag, attrs) do
      nil
    else
      {tag, attrs, remove(inner_tree)}
    end
  end
  defp unlikely_candidate?(tag, attrs) do
    idclass_str = attrs
                  |> Enum.filter_map(fn(attr) -> elem(attr, 0) =~ ~r/id|class/i end,
                                     fn(attr) -> elem(attr, 1) end)
                  |> Enum.join("")
    str = tag <> idclass_str

    str =~ Readability.regexes[:unlikelyCandidatesRe]
      && !(str =~ Readability.regexes[:okMaybeItsACandidateRe])
      && tag != "html"
  end
end
