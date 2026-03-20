defmodule Mix.Tasks.Proto.Sync do
  @moduledoc """
  Generates Ecto schemas, dbt staging models, and migrations from Protobuf descriptors.

  Uses `buf build` to produce a JSON FileDescriptorSet, then maps proto fields
  to Ecto types and dbt columns based on the manifest in `proto/persisted.exs`.

  ## Usage

      mix proto.sync          # Generate all files
      mix proto.sync --check  # Check for drift without writing

  ## How it works

  1. Loads the manifest from `proto/persisted.exs`
  2. Runs `buf build` to get the proto descriptor as JSON
  3. For each table in the manifest, extracts the proto message fields
  4. Generates an Ecto schema module (read-only, no changeset)
  5. Generates a dbt staging SQL view
  6. For new tables (`migration_exists: false`), generates a CREATE TABLE migration
  7. For existing tables, detects new proto fields and generates ADD COLUMN migrations
  8. In `--check` mode, compares generated output and detects migration gaps
  """

  use Mix.Task

  alias Mix.Tasks.ProtoSync.DbtGenerator
  alias Mix.Tasks.ProtoSync.Descriptor
  alias Mix.Tasks.ProtoSync.DriftChecker
  alias Mix.Tasks.ProtoSync.EctoGenerator
  alias Mix.Tasks.ProtoSync.Manifest
  alias Mix.Tasks.ProtoSync.MigrationGenerator

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

  defp run_generate(manifest, descriptor, repo_root) do
    core_root = Path.join(repo_root, "apps/core")
    dbt_root = Path.join(repo_root, "dbt/models/staging")
    migrations_dir = Path.join(core_root, "priv/repo/migrations")

    Enum.each(manifest.tables, fn table ->
      fields = Descriptor.extract_fields(descriptor, table.proto_file, table.proto_message)

      ecto_content = EctoGenerator.generate(table, fields)
      ecto_path = Path.join(core_root, table.ecto_path)
      File.mkdir_p!(Path.dirname(ecto_path))
      File.write!(ecto_path, ecto_content)
      Mix.shell().info("Generated #{ecto_path}")

      dbt_content = DbtGenerator.generate(table, fields)
      dbt_path = Path.join(dbt_root, table.dbt_path)
      File.mkdir_p!(Path.dirname(dbt_path))
      File.write!(dbt_path, dbt_content)
      Mix.shell().info("Generated #{dbt_path}")

      generate_migration(table, fields, migrations_dir)
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
    timestamp = MigrationGenerator.generate_timestamp()

    content = MigrationGenerator.generate_create_table(table, fields, timestamp)

    filename = "#{timestamp}_create_#{table.table_name}.exs"
    path = Path.join(migrations_dir, filename)
    File.mkdir_p!(migrations_dir)
    File.write!(path, content)
    Mix.shell().info("Generated migration #{path}")
  end

  defp generate_delta_migration(table, fields, migrations_dir) do
    existing = MigrationGenerator.existing_columns(migrations_dir, table.table_name)
    proto_field_names = Enum.map(fields, & &1.name)

    new_fields = Enum.filter(fields, fn field -> field.name not in existing end)

    # Also exclude timestamp columns that are added by the timestamps() macro
    new_fields =
      case Map.get(table, :timestamps) do
        :standard ->
          Enum.reject(new_fields, fn f -> f.name in ~w(created_at updated_at inserted_at) end)

        _ ->
          new_fields
      end

    if new_fields != [] do
      timestamp = MigrationGenerator.generate_timestamp()
      content = MigrationGenerator.generate_add_columns(table, new_fields, timestamp)

      slug = Enum.map_join(new_fields, "_", & &1.name)
      filename = "#{timestamp}_add_#{slug}_to_#{table.table_name}.exs"
      path = Path.join(migrations_dir, filename)
      File.write!(path, content)
      Mix.shell().info("Generated migration #{path}")
    else
      # Check for removed fields (warn only, additive-only convention)
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

  defp run_check(manifest, descriptor, repo_root) do
    core_root = Path.join(repo_root, "apps/core")
    dbt_root = Path.join(repo_root, "dbt/models/staging")
    migrations_dir = Path.join(core_root, "priv/repo/migrations")

    results =
      Enum.flat_map(manifest.tables, fn table ->
        fields = Descriptor.extract_fields(descriptor, table.proto_file, table.proto_message)

        ecto_result =
          DriftChecker.check(
            EctoGenerator.generate(table, fields),
            Path.join(core_root, table.ecto_path)
          )

        dbt_result =
          DriftChecker.check(
            DbtGenerator.generate(table, fields),
            Path.join(dbt_root, table.dbt_path)
          )

        migration_result = check_migration_drift(table, fields, migrations_dir)

        [ecto_result, dbt_result | migration_result]
      end)

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
    migration_exists = Map.get(table, :migration_exists, false)

    if migration_exists do
      # For existing tables, check if any proto fields are missing from migrations
      existing = MigrationGenerator.existing_columns(migrations_dir, table.table_name)
      proto_field_names = Enum.map(fields, & &1.name)
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
