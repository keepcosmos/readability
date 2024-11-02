defmodule Readability.PublishedAtFinder do
  @moduledoc """
  Extract the published at.
  """

  @type html_tree :: tuple | list

  @strategies [:meta_tag, :time_element, :data_attribute]

  @doc """
  Extract the published at.
  """
  @spec find(html_tree) :: %DateTime{} | %Date{} | nil
  def find(html_tree) do
    value =
      Enum.find_value(@strategies, fn strategy ->
        strategy(strategy, html_tree)
      end)

    if value do
      parse(value)
    end
  end

  defp strategy(:meta_tag, html_tree) do
    selector = "meta[property='article:published_time'], meta[property='article:published']"

    html_tree
    |> Floki.attribute(selector, "content")
    |> Enum.map(&String.trim/1)
    |> List.first()
  end

  defp strategy(:time_element, html_tree) do
    html_tree
    |> Floki.find("time")
    |> Enum.flat_map(&Floki.attribute(&1, "datetime"))
    |> Enum.map(&String.trim/1)
    |> List.first()
  end

  defp strategy(:data_attribute, html_tree) do
    html_tree
    |> Floki.find("[data-datetime]")
    |> Enum.flat_map(&Floki.attribute(&1, "data-datetime"))
    |> Enum.map(&String.trim/1)
    |> List.first()
  end

  defp parse(value) do
    parse(:datetime, value) || parse(:date, value)
  end

  defp parse(:datetime, value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse(:date, value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
