defmodule Readability.Sanitizer do
  @moduledoc """
  """

  alias Readability.Candidate
  alias Readability.Candidate.Scoring

  @type html_tree :: tuple | list

  @spec sanitize(html_tree, [Candidate.t], list) :: html_tree
  def sanitize(html_tree, candidates, opts \\ []) do

  end

  def abc([h|t]) do
    [abc(h)|abc(t)]
  end
  def abc(h) do
    h*2
  end


  def clean_headline_tag([h|t]) do

  end
  def clean_headline_tag({tag, attrs, inner_tree} = html_tree) do
    remove? = tag =~ ~r/^h\d{1}$/
              && (Scoring.class_weight(attrs) < 0 || Scoring.calc_link_density(html_tree) > 0.33)

    if remove? do
      clean_headline_tag(inner_tree)
    else
      {tag, attrs, clean_headline_tag(inner_tree)}
    end
  end
end
