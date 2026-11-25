defmodule Readability.Options do
  @moduledoc false

  # The deepest of Readability.js's 130 test pages nests 38 elements, generated and mutated test
  # documents at most as deep, and Blink's parser stops nesting at 512 levels (deeper elements
  # become siblings), so no page renders deeper than that in Chrome. 1000 leaves plenty of room
  # and keeps the parser's work per token (proportional to the depth) small; LazyHTML gives up
  # on deeper input without parsing the rest.
  # LazyHTML takes the limit as an unsigned 64-bit integer.
  @max_depth [
    type: {:or, [{:in, 1..0xFFFF_FFFF_FFFF_FFFF}, {:in, [:infinity]}]},
    default: 1000,
    doc: """
    Give up on documents whose elements nest deeper than this (`<html>` is at depth 1): parsing
    them takes time quadratic in the depth. A positive integer below 2^64, or `:infinity` for
    no limit. Doesn't apply to a `%LazyHTML{}`, which was parsed with the limits its caller
    chose.
    """
  ]

  # Defaults mirror Readability.js. Option names are its options in snake_case,
  # plus `:url`, since there's no document URL to read them from.
  @schema NimbleOptions.new!(
            url: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: """
              The page's URL. Relative links and image sources in the article are resolved
              against it and the page's `<base href>`. Without it, they're kept as they are,
              unless the page has an absolute `<base href>`.
              """
            ],
            char_threshold: [
              type: :pos_integer,
              default: 500,
              doc: """
              When the extracted text is shorter than this, extraction is retried with looser
              rules. If every attempt is short, the longest one is returned.
              """
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
            max_depth: @max_depth,
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
              doc: """
              Added to the link density thresholds (0.2, or 0.5 for blocks with a high class
              weight) above which a block is removed: positive values keep more link-heavy
              blocks, negative values remove more.
              """
            ],
            spawn: [
              type: :boolean,
              default: false,
              doc: """
              Do the work in a short-lived linked process, with a heap sized for the page: about a
              fifth faster on typical pages, and the memory is released at once instead of staying
              in the caller's heap until its next garbage collection. Worth it when you extract
              many pages. For HTML up to 2 MB, the heap starts at two words per byte (64 KB to 16 MB
              on a 64-bit VM); larger HTML starts with the default heap. Results, exceptions and
              exits reach the caller as usual, and the caller's `:max_heap_size` applies. The
              process doesn't inherit the caller's `$callers` or Logger metadata.
              """
            ]
          )

  @readerable_schema NimbleOptions.new!(
                       min_content_length: [
                         type: :pos_integer,
                         default: 140,
                         doc: "The minimum length of a paragraph's text for it to count."
                       ],
                       min_score: [
                         type: {:or, [:integer, :float]},
                         default: 20,
                         doc: "The score, summed over the paragraphs that count, the page must exceed."
                       ],
                       max_depth: @max_depth
                     )

  def docs, do: NimbleOptions.docs(@schema)

  def readerable_docs, do: NimbleOptions.docs(@readerable_schema)

  def validate_readerable!(opts), do: opts |> NimbleOptions.validate!(@readerable_schema) |> Map.new()

  # Returns a map; `:link_density_modifier` is always a float.
  def validate!(opts) do
    opts = opts |> NimbleOptions.validate!(@schema) |> Map.new()
    %{opts | link_density_modifier: opts.link_density_modifier / 1}
  end
end
