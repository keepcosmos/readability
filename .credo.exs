# `mix credo --strict` runs in CI. Credo's defaults, with these exclusions:
%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        extra: [
          # StreamData generators with one `case` branch per generated shape: splitting them
          # would only spread the shapes over more functions.
          {Credo.Check.Refactor.CyclomaticComplexity, files: %{excluded: ["test/support/html_gen.ex"]}}
        ]
      }
    }
  ]
}
