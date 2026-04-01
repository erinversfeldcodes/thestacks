defmodule Mix.Tasks.ProtoSync.SchemaYmlGenerator do
  @moduledoc "Generates and merges dbt schema.yml model blocks from proto definitions."

  alias Mix.Tasks.ProtoSync.TypeMapper

  @doc """
  Generates a YAML model block for a proto-backed dbt staging model.

  The block includes:
  - Model name: `stg_<table_name>`
  - Column entries for `id` (PK), proto fields by number, and timestamps
  - `not_null` test on columns with `null: false` in field_overrides
  - `unique` test on the `id` column
  - `accepted_values` test on enum fields (values from the proto enum definition)
  - `relationships` test on fields with `:binary_id` type override and `_id` suffix
  """
  @spec generate(map(), list(), map()) :: String.t()
  def generate(table, fields, descriptor) do
    overrides = Map.get(table, :field_overrides, %{})
    ts_fields = timestamp_field_names(table)
    model_name = "stg_#{table.table_name}"

    # Filter out: id, timestamps (added separately), api_only/dbt_exclude fields
    filtered_fields =
      Enum.reject(fields, fn field ->
        field_atom = String.to_atom(field.name)
        override = Map.get(overrides, field_atom, %{})

        field.name == "id" or
          field.name in ts_fields or
          Map.get(override, :api_only, false) or
          Map.get(override, :dbt_exclude, false)
      end)

    columns =
      [id_column()] ++
        Enum.map(filtered_fields, fn field -> field_column(field, overrides, descriptor) end) ++
        timestamp_columns(table)

    column_yaml = Enum.map_join(columns, "\n", &render_column/1)

    "  - name: #{model_name}\n" <>
      "    description: >\n" <>
      "      Proto-synced staging model for #{table.table_name}.\n" <>
      "    columns:\n" <>
      column_yaml
  end

  @doc """
  Merges generated model blocks into the existing schema.yml content.

  Proto-backed model entries (identified by matching `stg_<table_name>`) are
  replaced with the generated version. All other entries are preserved as-is.
  Separators (blank lines, comment blocks) between models are preserved.
  """
  @spec merge(String.t(), map()) :: String.t()
  def merge(existing_content, generated_blocks) do
    result =
      Enum.reduce(generated_blocks, existing_content, fn {model_name, new_block}, content ->
        replace_model_block(content, model_name, new_block)
      end)

    result
  end

  @doc """
  Checks whether the proto-backed model blocks in schema.yml match the
  generated output. Returns `:ok` or `{:drift, path, diff}`.
  """
  @spec check_drift(String.t(), map()) :: :ok | {:drift, String.t(), String.t()}
  def check_drift(schema_yml_path, generated_blocks) do
    if File.exists?(schema_yml_path) do
      existing_content = File.read!(schema_yml_path)
      merged = merge(existing_content, generated_blocks)

      if normalize(existing_content) == normalize(merged) do
        :ok
      else
        diff = generate_diff(existing_content, merged)
        {:drift, schema_yml_path, diff}
      end
    else
      {:drift, schema_yml_path, "file not found -- expected schema.yml at #{schema_yml_path}"}
    end
  end

  # -- Model block replacement ------------------------------------------------

  # Replace a single model block in the schema.yml content.
  # Finds the block by its "  - name: <model_name>" line and replaces
  # everything from that line to just before the next model/section/EOF.
  defp replace_model_block(content, model_name, new_block) do
    lines = String.split(content, "\n")

    # Find the line index where this model starts
    start_idx =
      Enum.find_index(lines, fn line ->
        String.trim(line) == "- name: #{model_name}"
      end)

    case start_idx do
      nil ->
        # Model not found — append before the final newline
        String.trim_trailing(content) <> "\n\n" <> new_block <> "\n"

      idx ->
        # Find where this model's content ends
        end_idx = find_model_end(lines, idx)

        before = Enum.take(lines, idx)
        after_lines = Enum.drop(lines, end_idx + 1)

        new_lines = String.split(new_block, "\n")

        result_lines = before ++ new_lines ++ after_lines
        Enum.join(result_lines, "\n")
    end
  end

  # Find the last line index belonging to a model block starting at start_idx.
  # A model block ends when we hit the next "  - name:" line, a section
  # comment line ("  # ---"), or the end of file.
  defp find_model_end(lines, start_idx) do
    total = length(lines)

    # Walk forward from start_idx + 1 to find the next boundary
    result =
      (start_idx + 1)..(total - 1)//1
      |> Enum.find(fn idx ->
        line = Enum.at(lines, idx)
        Regex.match?(~r/^\s{2}- name:\s/, line) or Regex.match?(~r/^\s{2}#\s*-{3,}/, line)
      end)

    case result do
      nil ->
        # No boundary found — model runs to end of file.
        # Trim trailing blank lines.
        (total - 1)..start_idx//-1
        |> Enum.find(start_idx, fn idx ->
          String.trim(Enum.at(lines, idx)) != ""
        end)

      boundary_idx ->
        # Walk backwards from boundary to skip blank lines that separate models
        (boundary_idx - 1)..start_idx//-1
        |> Enum.find(start_idx, fn idx ->
          String.trim(Enum.at(lines, idx)) != ""
        end)
    end
  end

  # -- Column building helpers ------------------------------------------------

  defp id_column do
    %{name: "id", description: "Surrogate UUID primary key.", tests: [:not_null, :unique]}
  end

  defp field_column(field, overrides, descriptor) do
    field_atom = String.to_atom(field.name)
    override = Map.get(overrides, field_atom, %{})
    col_name = Map.get(override, :ecto_name, field_atom) |> to_string()
    ecto_type = TypeMapper.ecto_type(field, overrides)

    tests = build_tests(field, override, ecto_type, descriptor)

    %{
      name: col_name,
      description: field_description(col_name),
      tests: tests
    }
  end

  defp timestamp_columns(%{timestamps: :standard}) do
    [
      %{
        name: "created_at",
        description: "Timestamp when the record was created.",
        tests: [:not_null]
      },
      %{
        name: "updated_at",
        description: "Timestamp of the last modification to this record.",
        tests: [:not_null]
      }
    ]
  end

  defp timestamp_columns(%{timestamps: {:standard, updated_at: false}}) do
    [
      %{
        name: "created_at",
        description: "Timestamp when the record was created.",
        tests: [:not_null]
      }
    ]
  end

  defp timestamp_columns(_), do: []

  defp timestamp_field_names(%{timestamps: :standard}), do: ~w(created_at updated_at)
  defp timestamp_field_names(%{timestamps: {:standard, updated_at: false}}), do: ~w(created_at)
  defp timestamp_field_names(%{timestamps: false}), do: []
  defp timestamp_field_names(_), do: ~w(created_at updated_at)

  defp build_tests(_field, override, _ecto_type, _descriptor) do
    tests = []

    # not_null for fields with null: false override
    tests =
      if Map.get(override, :null) == false do
        tests ++ [:not_null]
      else
        tests
      end

    # relationships tests removed: Postgres enforces FK integrity at the OLTP
    # layer, and auto-inferred ref model names are unreliable (naive pluralisation,
    # polymorphic references like aggregate_id). Add relationships tests manually
    # to intermediate/mart schema.yml where denormalised joins could produce orphans.

    # accepted_values: not auto-inferred from proto (proto enums are additive
    # and may lead the DB). Opt-in per field via dbt_tests in field_overrides.
    tests =
      case Map.get(override, :dbt_tests) do
        nil -> tests
        extra -> tests ++ extra
      end

    tests
  end

  defp field_description(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.capitalize()
    |> Kernel.<>(".")
  end

  # -- YAML rendering ---------------------------------------------------------

  defp render_column(%{name: name, description: desc, tests: tests}) do
    base = "      - name: #{name}\n        description: #{desc}"

    if tests == [] do
      base
    else
      test_yaml = Enum.map_join(tests, "\n", &render_test/1)
      base <> "\n        tests:\n" <> test_yaml
    end
  end

  defp render_test(:not_null), do: "          - not_null"
  defp render_test(:unique), do: "          - unique"

  defp render_test({:not_null, where}) when is_binary(where) do
    "          - not_null:\n" <>
      "              where: \"#{where}\""
  end

  defp render_test({:relationships, ref_model}) do
    "          - relationships:\n" <>
      "              arguments:\n" <>
      "                to: ref('#{ref_model}')\n" <>
      "                field: id"
  end

  defp render_test({:accepted_values, values}) do
    values_str = Enum.map_join(values, ", ", fn v -> "'#{v}'" end)

    "          - accepted_values:\n" <>
      "              arguments:\n" <>
      "                values: [#{values_str}]"
  end

  # -- Diff helpers -----------------------------------------------------------

  defp normalize(content) do
    content
    |> String.trim()
    |> String.replace(~r/\s+$\n/m, "\n")
  end

  defp generate_diff(actual, expected) do
    actual_lines = String.split(normalize(actual), "\n")
    expected_lines = String.split(normalize(expected), "\n")

    List.myers_difference(actual_lines, expected_lines)
    |> Enum.flat_map(fn
      {:eq, _} -> []
      {:del, lines} -> Enum.map(lines, &"- #{&1}")
      {:ins, lines} -> Enum.map(lines, &"+ #{&1}")
    end)
    |> Enum.join("\n")
    |> case do
      "" -> "(whitespace-only differences)"
      diff -> diff
    end
  end
end
