defmodule Readability.Options do
  @moduledoc false

  # Defaults mirror Readability.js. Option names are its options in snake_case,
  # plus `:url`, since there's no document URL to read them from.
  @schema NimbleOptions.new!(
            url: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: """
              The page's URL. Relative links and image sources in the article are resolved
              against it (and against the page's `<base href>`). Without it, they're kept as they are.
              """
            ],
            char_threshold: [
              type: :pos_integer,
              default: 500,
              doc: "The minimum number of characters an article must have to be returned as is."
            ],
            nb_top_candidates: [
              type: :pos_integer,
              default: 5,
              doc: "How many top-scoring candidates to compare when picking the article's container."
            ],
            max_elems_to_parse: [
              type: :non_neg_integer,
              default: 0,
              doc: "Give up on pages with more elements than this. `0` means no limit."
            ],
            classes_to_preserve: [
              type: {:list, :string},
              default: [],
              doc:
                "Class names to keep in the content, in addition to `\"page\"`. Others are removed unless `:keep_classes` is set."
            ],
            keep_classes: [
              type: :boolean,
              default: false,
              doc: "Keep every `class` attribute in the content."
            ],
            disable_json_ld: [
              type: :boolean,
              default: false,
              doc: "Don't read metadata from JSON-LD (`<script type=\"application/ld+json\">`)."
            ],
            allowed_video_regex: [
              type: {:or, [{:struct, Regex}, nil]},
              default: nil,
              doc:
                "Embeds (`iframe`, `embed`, `object`) are kept when any of their attribute values matches this. Defaults to Readability.js's list of common video hosts."
            ],
            link_density_modifier: [
              type: {:or, [:float, :integer]},
              default: 0.0,
              doc: "Added to the link density threshold when deciding whether to remove a block."
            ]
          )

  def schema, do: @schema

  def docs, do: NimbleOptions.docs(@schema)

  # Returns a map; `:link_density_modifier` is always a float.
  def validate!(opts) do
    opts = opts |> NimbleOptions.validate!(@schema) |> Map.new()
    %{opts | link_density_modifier: opts.link_density_modifier / 1}
  end
end
