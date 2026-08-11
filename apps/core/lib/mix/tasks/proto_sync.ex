defmodule Mix.Tasks.Proto.Sync do
  @moduledoc """
      Generates Ecto schemas, dbt staging models, and migrations from proto
      descriptors: `buf build` → JSON FileDescriptorSet, mapped per the
      `proto/persisted.exs` manifest. New tables get CREATE TABLE migrations;
      new proto fields on existing tables get ADD COLUMN. `--check` compares
      output and detects migration gaps without writing (runs in CI; drift
      fails the build).
  """

  use Mix.Task

  @requirements []

  alias Mix.Tasks.ProtoSync.DbtGenerator
  alias Mix.Tasks.ProtoSync.Descriptor
  alias Mix.Tasks.ProtoSync.DriftChecker
  alias Mix.Tasks.ProtoSync.EctoGenerator
  alias Mix.Tasks.ProtoSync.Manifest
  alias Mix.Tasks.ProtoSync.MigrationGenerator
  alias Mix.Tasks.ProtoSync.ProtoJsonGenerator
  alias Mix.Tasks.ProtoSync.SchemaYmlGenerator

  @shortdoc "Generate Ecto schemas, dbt models, and migrations from proto definitions"

  @impl Mix.Task
  def run(args) do
    check_mode = "--check" in args
    repo_root = find_repo_root()

    manifest = Manifest.load!(Path.join(repo_root, "proto/persisted.exs"))
    descriptor = Descriptor.parse!(repo_root)

    if check_mode do
      run_check(manifest, descriptor, repo_root)
    else
      run_generate(manifest, descriptor, repo_root)
    end
  end

  @doc false
  def run_generate(manifest, descriptor, repo_root) do
    core_root = Path.join(repo_root, "apps/core")
    dbt_root = Path.join(repo_root, "dbt/models/staging")
    migrations_dir = Path.join(core_root, "priv/repo/migrations")
    schema_yml_path = Path.join(dbt_root, "schema.yml")

    generated_blocks =
      Enum.reduce(manifest.tables, %{}, fn table, blocks ->
        fields = Descriptor.extract_fields(descriptor, table.proto_file, table.proto_message)

        unless Map.get(table, :skip_ecto, false) do
          ecto_content = EctoGenerator.generate(table, fields)
          ecto_path = Path.join(core_root, table.ecto_path)
          File.mkdir_p!(Path.dirname(ecto_path))
          File.write!(ecto_path, ecto_content)
          Mix.shell().info("Generated #{ecto_path}")
        end

        generate_migration(table, fields, migrations_dir)

        if Map.get(table, :skip_dbt, false) do
          blocks
        else
          dbt_content = DbtGenerator.generate(table, fields)
          dbt_path = Path.join(dbt_root, table.dbt_path)
          File.mkdir_p!(Path.dirname(dbt_path))
          File.write!(dbt_path, dbt_content)
          Mix.shell().info("Generated #{dbt_path}")

          model_name = "stg_#{table.table_name}"
          block = SchemaYmlGenerator.generate(table, fields, descriptor)
          Map.put(blocks, model_name, block)
        end
      end)

    if File.exists?(schema_yml_path) do
      existing = File.read!(schema_yml_path)
      merged = SchemaYmlGenerator.merge(existing, generated_blocks)
      File.write!(schema_yml_path, merged)
      Mix.shell().info("Updated #{schema_yml_path}")
    else
      Mix.shell().info("Skipped schema.yml — file not found at #{schema_yml_path}")
    end

    if Map.has_key?(manifest, :proto_json) and manifest.proto_json != [] do
      proto_json_content = ProtoJsonGenerator.generate(manifest, descriptor)
      proto_json_path = Path.join(core_root, "lib/stacks/gen/proto_json.ex")
      File.mkdir_p!(Path.dirname(proto_json_path))
      File.write!(proto_json_path, proto_json_content)
      Mix.shell().info("Generated #{proto_json_path}")
    end

    gen_dir = Path.join(core_root, "lib/stacks/gen")

    ecto_locals = [
      field: 1,
      field: 2,
      field: 3,
      timestamps: 1,
      belongs_to: 2,
      belongs_to: 3,
      has_one: 2,
      has_one: 3,
      has_many: 2,
      has_many: 3
    ]

    gen_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      formatted =
        path
        |> File.read!()
        |> Code.format_string!(locals_without_parens: ecto_locals)
        |> IO.iodata_to_binary()

      File.write!(path, [formatted, "\n"])
    end)

    Mix.shell().info("Proto sync complete.")
  end

  defp generate_migration(table, fields, migrations_dir) do
    migration_exists = Map.get(table, :migration_exists, false)

    if migration_exists do
      generate_delta_migration(table, fields, migrations_dir)
    else
      generate_create_migration(table, fields, migrations_dir)
    end
  end

  defp generate_create_migration(table, fields, migrations_dir) do
    already_exists =
      File.dir?(migrations_dir) and
        migrations_dir
        |> File.ls!()
        |> Enum.any?(&String.contains?(&1, "create_#{table.table_name}.exs"))

    if already_exists do
      Mix.shell().info("Skipping migration for #{table.table_name} — already exists")
    else
      timestamp = MigrationGenerator.generate_timestamp()
      content = MigrationGenerator.generate_create_table(table, fields, timestamp)

      filename = "#{timestamp}_create_#{table.table_name}.exs"
      path = Path.join(migrations_dir, filename)
      File.mkdir_p!(migrations_dir)
      File.write!(path, content)
      Mix.shell().info("Generated migration #{path}")
    end
  end

  defp generate_delta_migration(table, fields, migrations_dir) do
    overrides = Map.get(table, :field_overrides, %{})
    ts_fields = timestamp_field_names(table)

    db_fields =
      Enum.reject(fields, fn field ->
        field.name == "id" or field.name in ts_fields or api_only_field?(field, overrides)
      end)

    existing = MigrationGenerator.existing_columns(migrations_dir, table.table_name)
    proto_field_names = Enum.map(db_fields, & &1.name)

    new_fields = Enum.filter(db_fields, fn field -> field.name not in existing end)

    if new_fields != [] do
      timestamp = MigrationGenerator.generate_timestamp()
      content = MigrationGenerator.generate_add_columns(table, new_fields, timestamp)

      slug = MigrationGenerator.add_columns_slug(new_fields, table.table_name)
      path = Path.join(migrations_dir, "#{timestamp}_#{slug}.exs")
      File.mkdir_p!(migrations_dir)
      File.write!(path, content)
      Mix.shell().info("Generated migration #{path}")
    else
      timestamp_cols = ~w(created_at updated_at inserted_at)

      existing
      |> Enum.reject(fn col -> col in proto_field_names or col in timestamp_cols end)
      |> Enum.each(fn col ->
        Mix.shell().info(
          "Note: column '#{col}' exists in migrations for #{table.table_name} but not in proto. " <>
            "Per additive-only convention, no DROP COLUMN generated."
        )
      end)
    end
  end

  defp api_only_field?(field, overrides) do
    field_name = String.to_atom(field.name)
    override = Map.get(overrides, field_name, %{})
    Map.get(override, :api_only, false)
  end

  defp timestamp_field_names(%{timestamps: :standard}), do: ~w(created_at updated_at)
  defp timestamp_field_names(%{timestamps: {:standard, updated_at: false}}), do: ~w(created_at)
  defp timestamp_field_names(%{timestamps: false}), do: []
  defp timestamp_field_names(_), do: ~w(created_at updated_at)

  defp run_check(manifest, descriptor, repo_root) do
    core_root = Path.join(repo_root, "apps/core")
    dbt_root = Path.join(repo_root, "dbt/models/staging")
    migrations_dir = Path.join(core_root, "priv/repo/migrations")
    schema_yml_path = Path.join(dbt_root, "schema.yml")

    {results, generated_blocks} =
      Enum.map_reduce(manifest.tables, %{}, fn table, blocks_acc ->
        fields = Descriptor.extract_fields(descriptor, table.proto_file, table.proto_message)

        ecto_results =
          if Map.get(table, :skip_ecto, false) do
            []
          else
            [
              DriftChecker.check(
                EctoGenerator.generate(table, fields),
                Path.join(core_root, table.ecto_path),
                repo_root
              )
            ]
          end

        migration_result = check_migration_drift(table, fields, migrations_dir)

        if Map.get(table, :skip_dbt, false) do
          {ecto_results ++ migration_result, blocks_acc}
        else
          dbt_result =
            DriftChecker.check(
              DbtGenerator.generate(table, fields),
              Path.join(dbt_root, table.dbt_path),
              repo_root
            )

          model_name = "stg_#{table.table_name}"
          block = SchemaYmlGenerator.generate(table, fields, descriptor)
          blocks_acc = Map.put(blocks_acc, model_name, block)

          {ecto_results ++ [dbt_result | migration_result], blocks_acc}
        end
      end)

    results = List.flatten(results)

    schema_yml_result = SchemaYmlGenerator.check_drift(schema_yml_path, generated_blocks)
    results = results ++ List.wrap(schema_yml_result)

    results =
      if Map.has_key?(manifest, :proto_json) and manifest.proto_json != [] do
        proto_json_content = ProtoJsonGenerator.generate(manifest, descriptor)
        proto_json_path = Path.join(core_root, "lib/stacks/gen/proto_json.ex")
        proto_json_result = DriftChecker.check(proto_json_content, proto_json_path, repo_root)
        results ++ List.wrap(proto_json_result)
      else
        results
      end

    for {:regenerated, path} <- results do
      Mix.shell().info(
        "REGENERATED: #{path} was stale — gitignored, so this can only be " <>
          "local staleness; regenerated from proto and continuing."
      )
    end

    drifted = Enum.filter(results, &match?({:drift, _, _}, &1))

    if drifted == [] do
      Mix.shell().info("All generated files are up to date.")
    else
      Enum.each(drifted, fn {:drift, path, diff} ->
        Mix.shell().error("Drift detected in #{path}:")
        Mix.shell().error(diff)
      end)

      raise("Proto sync drift detected. Run `mix proto.sync` to fix.")
    end
  end

  defp check_migration_drift(table, fields, migrations_dir) do
    overrides = Map.get(table, :field_overrides, %{})
    ts_fields = timestamp_field_names(table)
    migration_exists = Map.get(table, :migration_exists, false)

    db_fields =
      Enum.reject(fields, fn field ->
        field.name == "id" or field.name in ts_fields or api_only_field?(field, overrides)
      end)

    if migration_exists do
      existing = MigrationGenerator.existing_columns(migrations_dir, table.table_name)
      proto_field_names = Enum.map(db_fields, & &1.name)
      missing = Enum.reject(proto_field_names, fn name -> name in existing end)

      if missing != [] do
        cols = missing |> Enum.sort() |> Enum.join(", ")

        [
          {:drift, "migrations/#{table.table_name}",
           "Proto fields missing from migrations: #{cols}. Run `mix proto.sync` to generate an ADD COLUMN migration."}
        ]
      else
        []
      end
    else
      check_new_table_migration(table, migrations_dir)
    end
  end

  defp check_new_table_migration(table, migrations_dir) do
    has_migration =
      if File.dir?(migrations_dir) do
        migrations_dir
        |> File.ls!()
        |> Enum.any?(fn f ->
          String.contains?(f, "create_#{table.table_name}") and String.ends_with?(f, ".exs")
        end)
      else
        false
      end

    if has_migration do
      []
    else
      [
        {:drift, "migrations/#{table.table_name}",
         "No CREATE TABLE migration found. Run `mix proto.sync` to generate."}
      ]
    end
  end

  defp find_repo_root do
    cwd = File.cwd!()

    cond do
      File.exists?(Path.join(cwd, "proto/persisted.exs")) ->
        cwd

      File.exists?(Path.join(cwd, "../../proto/persisted.exs")) ->
        Path.expand("../..", cwd)

      true ->
        case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
          {root, 0} -> String.trim(root)
          _ -> raise("Cannot find repo root. Run from the repo root or apps/core/.")
        end
    end
  end
end
