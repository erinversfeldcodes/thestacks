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
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.MaxLineLength, [max_length: 120]}
        ]
      }
    }
  ]
}
