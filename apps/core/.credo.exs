%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: true,
      color: true,
      checks: %{
        disabled: [
          # Allow IO.inspect in tests
          {Credo.Check.Warning.IoInspect, []},
          # Modules can have underscores
          {Credo.Check.Readability.ModuleDoc, []},
          # Allow long lines in some cases
          {Credo.Check.Readability.MaxLineLength, [max_length: 120]}
        ]
      }
    }
  ]
}
