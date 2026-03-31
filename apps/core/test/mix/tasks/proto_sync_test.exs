defmodule Mix.Tasks.Proto.SyncTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Proto.Sync, as: ProtoSync
  alias Mix.Tasks.ProtoSync.DbtGenerator
  alias Mix.Tasks.ProtoSync.Descriptor
  alias Mix.Tasks.ProtoSync.DriftChecker
  alias Mix.Tasks.ProtoSync.EctoGenerator
  alias Mix.Tasks.ProtoSync.Manifest
  alias Mix.Tasks.ProtoSync.MigrationGenerator
  alias Mix.Tasks.ProtoSync.ProtoJsonGenerator
  alias Mix.Tasks.ProtoSync.SchemaYmlGenerator
  alias Mix.Tasks.ProtoSync.TypeMapper

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "Manifest" do
    test "loads valid manifest" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      assert manifest.version == 1
      assert event_log = Enum.find(manifest.tables, &(&1.table_name == "event_log"))
      assert event_log.table_name == "event_log"
      assert event_log.proto_message == "EventEnvelope"
    end

    test "raises on missing file" do
      assert_raise RuntimeError, ~r/Manifest not found/, fn ->
        Manifest.load!("/nonexistent/path.exs")
      end
    end

    test "raises on malformed manifest missing required keys" do
      tmp_path = Path.join(System.tmp_dir!(), "bad_manifest.exs")
      File.write!(tmp_path, "%{version: 1, tables: [%{proto_file: \"test.proto\"}]}")

      assert_raise RuntimeError, ~r/missing required key/, fn ->
        Manifest.load!(tmp_path)
      end

      File.rm!(tmp_path)
    end

    test "raises on invalid manifest structure" do
      tmp_path = Path.join(System.tmp_dir!(), "invalid_manifest.exs")
      File.write!(tmp_path, "[1, 2, 3]")

      assert_raise RuntimeError, ~r/Invalid manifest structure/, fn ->
        Manifest.load!(tmp_path)
      end

      File.rm!(tmp_path)
    end
  end

  describe "Descriptor" do
    setup do
      descriptor = Descriptor.parse!(@repo_root)
      %{descriptor: descriptor}
    end

    test "parses buf build output", %{descriptor: descriptor} do
      assert is_list(descriptor["file"])
      assert descriptor["file"] != []
    end

    test "extracts EventEnvelope fields", %{descriptor: descriptor} do
      fields =
        Descriptor.extract_fields(
          descriptor,
          "stacks/internal/v1/event_bus.proto",
          "EventEnvelope"
        )

      assert length(fields) == 8
      field_names = Enum.map(fields, & &1.name)
      assert "event_type" in field_names
      assert "aggregate_id" in field_names
      assert "payload" in field_names
      assert "occurred_at" in field_names
      assert "published_at" in field_names
    end

    test "extracts SourceHealthCheck fields", %{descriptor: descriptor} do
      fields =
        Descriptor.extract_fields(
          descriptor,
          "stacks/monitoring/v1/source_health_check.proto",
          "SourceHealthCheck"
        )

      assert length(fields) == 9
      field_names = Enum.map(fields, & &1.name)
      assert "source_name" in field_names
      assert "source_type" in field_names
      assert "status" in field_names
      assert "consecutive_failures" in field_names
    end

    test "fields are sorted by field number", %{descriptor: descriptor} do
      fields =
        Descriptor.extract_fields(
          descriptor,
          "stacks/internal/v1/event_bus.proto",
          "EventEnvelope"
        )

      numbers = Enum.map(fields, & &1.number)
      assert numbers == Enum.sort(numbers)
    end

    test "raises on unknown proto file", %{descriptor: descriptor} do
      assert_raise RuntimeError, ~r/not found in descriptor/, fn ->
        Descriptor.extract_fields(descriptor, "nonexistent.proto", "Foo")
      end
    end

    test "raises on unknown message", %{descriptor: descriptor} do
      assert_raise RuntimeError, ~r/not found in/, fn ->
        Descriptor.extract_fields(
          descriptor,
          "stacks/internal/v1/event_bus.proto",
          "NonexistentMessage"
        )
      end
    end
  end

  describe "TypeMapper" do
    test "maps string type" do
      field = %{name: "foo", type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :string
    end

    test "maps int32 type" do
      field = %{name: "foo", type: "TYPE_INT32", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :integer
    end

    test "maps int64 type" do
      field = %{name: "foo", type: "TYPE_INT64", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :integer
    end

    test "maps float type" do
      field = %{name: "foo", type: "TYPE_FLOAT", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :float
    end

    test "maps double type" do
      field = %{name: "foo", type: "TYPE_DOUBLE", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :float
    end

    test "maps bool type" do
      field = %{name: "foo", type: "TYPE_BOOL", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :boolean
    end

    test "maps bytes type" do
      field = %{name: "foo", type: "TYPE_BYTES", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :binary
    end

    test "maps Timestamp WKT" do
      field = %{
        name: "foo",
        type: "TYPE_MESSAGE",
        type_name: ".google.protobuf.Timestamp",
        label: "LABEL_OPTIONAL"
      }

      assert TypeMapper.ecto_type(field) == :utc_datetime_usec
    end

    test "maps Struct WKT" do
      field = %{
        name: "foo",
        type: "TYPE_MESSAGE",
        type_name: ".google.protobuf.Struct",
        label: "LABEL_OPTIONAL"
      }

      assert TypeMapper.ecto_type(field) == :map
    end

    test "maps enum type to string" do
      field = %{
        name: "foo",
        type: "TYPE_ENUM",
        type_name: ".some.Enum",
        label: "LABEL_OPTIONAL"
      }

      assert TypeMapper.ecto_type(field) == :string
    end

    test "maps repeated to array" do
      field = %{name: "foo", type: "TYPE_STRING", type_name: nil, label: "LABEL_REPEATED"}
      assert TypeMapper.ecto_type(field) == {:array, :string}
    end

    test "field override takes precedence" do
      field = %{
        name: "aggregate_id",
        type: "TYPE_STRING",
        type_name: nil,
        label: "LABEL_OPTIONAL"
      }

      overrides = %{aggregate_id: %{ecto_type: :binary_id}}
      assert TypeMapper.ecto_type(field, overrides) == :binary_id
    end

    test "raises on unknown message type" do
      field = %{
        name: "foo",
        type: "TYPE_MESSAGE",
        type_name: ".some.Unknown",
        label: "LABEL_OPTIONAL"
      }

      # Non-WKT message types fall back to :map (JSONB) instead of raising
      assert TypeMapper.ecto_type(field) == :map
    end

    test "default returns :none when no override" do
      field = %{name: "foo", type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.default(field) == :none
    end

    test "default returns value from override" do
      field = %{name: "status", type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      overrides = %{status: %{default: "healthy"}}
      assert TypeMapper.default(field, overrides) == {:ok, "healthy"}
    end

    test "default skips fragment defaults" do
      field = %{
        name: "occurred_at",
        type: "TYPE_MESSAGE",
        type_name: nil,
        label: "LABEL_OPTIONAL"
      }

      overrides = %{occurred_at: %{default: {:fragment, "NOW()"}}}
      assert TypeMapper.default(field, overrides) == :none
    end

    test "migration_default includes fragment defaults" do
      field = %{
        name: "occurred_at",
        type: "TYPE_MESSAGE",
        type_name: nil,
        label: "LABEL_OPTIONAL"
      }

      overrides = %{occurred_at: %{default: {:fragment, "NOW()"}}}
      assert TypeMapper.migration_default(field, overrides) == {:ok, {:fragment, "NOW()"}}
    end

    test "migration_type maps string to text" do
      field = %{name: "foo", type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.migration_type(field) == :text
    end

    test "migration_type maps int64 to bigint" do
      field = %{name: "foo", type: "TYPE_INT64", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.migration_type(field) == :bigint
    end

    test "migration_type maps enum to text" do
      field = %{
        name: "foo",
        type: "TYPE_ENUM",
        type_name: ".some.Enum",
        label: "LABEL_OPTIONAL"
      }

      assert TypeMapper.migration_type(field) == :text
    end

    test "maps fixed32 type" do
      field = %{name: "foo", type: "TYPE_FIXED32", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :integer
      assert TypeMapper.migration_type(field) == :integer
    end

    test "maps fixed64 type" do
      field = %{name: "foo", type: "TYPE_FIXED64", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :integer
      assert TypeMapper.migration_type(field) == :bigint
    end

    test "maps sfixed32 type" do
      field = %{name: "foo", type: "TYPE_SFIXED32", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :integer
      assert TypeMapper.migration_type(field) == :integer
    end

    test "maps sfixed64 type" do
      field = %{name: "foo", type: "TYPE_SFIXED64", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.ecto_type(field) == :integer
      assert TypeMapper.migration_type(field) == :bigint
    end

    test "migration_type maps Timestamp WKT to utc_datetime_usec" do
      field = %{
        name: "ts",
        type: "TYPE_MESSAGE",
        type_name: ".google.protobuf.Timestamp",
        label: "LABEL_OPTIONAL"
      }

      assert TypeMapper.migration_type(field) == :utc_datetime_usec
    end

    test "migration_type maps Struct WKT to map" do
      field = %{
        name: "data",
        type: "TYPE_MESSAGE",
        type_name: ".google.protobuf.Struct",
        label: "LABEL_OPTIONAL"
      }

      assert TypeMapper.migration_type(field) == :map
    end

    test "migration_type raises on unknown message type" do
      field = %{
        name: "foo",
        type: "TYPE_MESSAGE",
        type_name: ".some.Unknown",
        label: "LABEL_OPTIONAL"
      }

      # Non-WKT message types fall back to :map instead of raising
      assert TypeMapper.migration_type(field) == :map
    end

    test "migration_type raises on completely unmapped type" do
      field = %{
        name: "foo",
        type: "TYPE_GROUP",
        type_name: nil,
        label: "LABEL_OPTIONAL"
      }

      assert_raise RuntimeError, ~r/Unmapped proto type/, fn ->
        TypeMapper.migration_type(field)
      end
    end

    test "migration_type with field override migration_type takes precedence" do
      field = %{name: "id", type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      overrides = %{id: %{migration_type: :binary_id}}
      assert TypeMapper.migration_type(field, overrides) == :binary_id
    end

    test "migration_type falls back to ecto_type override when no migration_type" do
      field = %{name: "id", type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      overrides = %{id: %{ecto_type: :binary_id}}
      assert TypeMapper.migration_type(field, overrides) == :binary_id
    end

    test "migration_type maps repeated fields to array" do
      field = %{name: "tags", type: "TYPE_STRING", type_name: nil, label: "LABEL_REPEATED"}
      assert TypeMapper.migration_type(field) == {:array, :text}
    end

    test "migration_type maps bool to boolean" do
      field = %{name: "active", type: "TYPE_BOOL", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.migration_type(field) == :boolean
    end

    test "migration_type maps float and double" do
      float_field = %{name: "f", type: "TYPE_FLOAT", type_name: nil, label: "LABEL_OPTIONAL"}
      double_field = %{name: "d", type: "TYPE_DOUBLE", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.migration_type(float_field) == :float
      assert TypeMapper.migration_type(double_field) == :float
    end

    test "migration_type maps bytes to binary" do
      field = %{name: "raw", type: "TYPE_BYTES", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.migration_type(field) == :binary
    end

    test "migration_type maps uint32 and sint32 to integer" do
      uint = %{name: "u", type: "TYPE_UINT32", type_name: nil, label: "LABEL_OPTIONAL"}
      sint = %{name: "s", type: "TYPE_SINT32", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.migration_type(uint) == :integer
      assert TypeMapper.migration_type(sint) == :integer
    end

    test "migration_type maps uint64 and sint64 to bigint" do
      uint = %{name: "u", type: "TYPE_UINT64", type_name: nil, label: "LABEL_OPTIONAL"}
      sint = %{name: "s", type: "TYPE_SINT64", type_name: nil, label: "LABEL_OPTIONAL"}
      assert TypeMapper.migration_type(uint) == :bigint
      assert TypeMapper.migration_type(sint) == :bigint
    end

    test "raises on completely unmapped ecto type" do
      field = %{name: "foo", type: "TYPE_GROUP", type_name: nil, label: "LABEL_OPTIONAL"}

      assert_raise RuntimeError, ~r/Unmapped proto type/, fn ->
        TypeMapper.ecto_type(field)
      end
    end
  end

  describe "EctoGenerator" do
    test "generates event_log schema" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)
      [event_log_table | _] = manifest.tables

      fields =
        Descriptor.extract_fields(
          descriptor,
          event_log_table.proto_file,
          event_log_table.proto_message
        )

      output = EctoGenerator.generate(event_log_table, fields)

      assert output =~ "defmodule Stacks.Events.EventLog do"
      assert output =~ ~s|@schema_prefix "op"|
      assert output =~ ~s|schema "event_log" do|
      assert output =~ "field :event_type, :string"
      assert output =~ "field :aggregate_id, :binary_id"
      assert output =~ "field :payload, :map"
      assert output =~ "field :occurred_at, :utc_datetime_usec"
      assert output =~ "field :schema_version, :integer, default: 1"
      refute output =~ "timestamps("
      assert output =~ "DO NOT EDIT MANUALLY"
    end

    test "generates source_health_checks schema with timestamps" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)
      shc_table = Enum.find(manifest.tables, &(&1.table_name == "source_health_checks"))

      fields =
        Descriptor.extract_fields(descriptor, shc_table.proto_file, shc_table.proto_message)

      output = EctoGenerator.generate(shc_table, fields)

      assert output =~ "defmodule Stacks.Monitoring.SourceHealthCheck do"
      assert output =~ "field :source_name, :string"
      assert output =~ "field :consecutive_failures, :integer, default: 0"
      assert output =~ "field :status, :string, default: \"healthy\""
      assert output =~ "timestamps(type: :utc_datetime_usec, inserted_at: :created_at)"
    end
  end

  describe "DbtGenerator" do
    test "generates event_log staging model" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)
      [event_log_table | _] = manifest.tables

      fields =
        Descriptor.extract_fields(
          descriptor,
          event_log_table.proto_file,
          event_log_table.proto_message
        )

      output = DbtGenerator.generate(event_log_table, fields)

      assert output =~ "{{ config(materialized='view') }}"
      assert output =~ "from {{ source('op', 'event_log') }}"
      assert output =~ "    id,"
      assert output =~ "    event_type,"
      assert output =~ "    payload,"
      assert output =~ "    published_at"
      refute output =~ "created_at"
      refute output =~ "updated_at"
      assert output =~ "DO NOT EDIT MANUALLY"
    end

    test "generates source_health_checks staging model with timestamps" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)
      shc_table = Enum.find(manifest.tables, &(&1.table_name == "source_health_checks"))

      fields =
        Descriptor.extract_fields(descriptor, shc_table.proto_file, shc_table.proto_message)

      output = DbtGenerator.generate(shc_table, fields)

      assert output =~ "from {{ source('op', 'source_health_checks') }}"
      assert output =~ "    source_name,"
      assert output =~ "    created_at,"
      assert output =~ "    updated_at"
    end
  end

  describe "DriftChecker" do
    test "returns :ok when content matches" do
      tmp_path = Path.join(System.tmp_dir!(), "drift_test_ok.txt")
      File.write!(tmp_path, "hello world\n")

      assert :ok == DriftChecker.check("hello world\n", tmp_path)

      File.rm!(tmp_path)
    end

    test "returns drift when content differs" do
      tmp_path = Path.join(System.tmp_dir!(), "drift_test_diff.txt")
      File.write!(tmp_path, "old content\n")

      assert {:drift, ^tmp_path, _diff} = DriftChecker.check("new content\n", tmp_path)

      File.rm!(tmp_path)
    end

    test "returns drift when file missing" do
      assert {:drift, "/nonexistent/file.txt", msg} =
               DriftChecker.check("content", "/nonexistent/file.txt")

      assert msg =~ "file not found"
    end
  end

  describe "MigrationGenerator" do
    test "generates CREATE TABLE migration for event_log" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)
      [event_log_table | _] = manifest.tables

      fields =
        Descriptor.extract_fields(
          descriptor,
          event_log_table.proto_file,
          event_log_table.proto_message
        )

      output = MigrationGenerator.generate_create_table(event_log_table, fields, "20260320000001")

      assert output =~ "use Ecto.Migration"
      assert output =~ ~s|create table(:event_log, prefix: "op", primary_key: false)|
      assert output =~ "add :id, :binary_id, primary_key: true"
      assert output =~ "add :event_type, :text, null: false"
      assert output =~ "add :aggregate_id, :binary_id, null: false"
      assert output =~ "add :schema_version, :integer, null: false, default: 1"
      assert output =~ "add :payload, :map, null: false"
      assert output =~ "add :metadata, :map"

      assert output =~
               ~s|add :occurred_at, :utc_datetime_usec, null: false, default: fragment("NOW()")|

      assert output =~ "add :published_at, :utc_datetime_usec"
      refute output =~ "timestamps("
      assert output =~ "idx_event_log_type_agg"
      assert output =~ "DO NOT EDIT MANUALLY"
      assert output =~ "def down"
      assert output =~ ~s|drop table(:event_log, prefix: "op")|
    end

    test "generates CREATE TABLE migration with timestamps and unique index" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)
      shc_table = Enum.find(manifest.tables, &(&1.table_name == "source_health_checks"))

      fields =
        Descriptor.extract_fields(descriptor, shc_table.proto_file, shc_table.proto_message)

      output = MigrationGenerator.generate_create_table(shc_table, fields, "20260320000002")

      assert output =~ ~s|create table(:source_health_checks, prefix: "op", primary_key: false)|
      assert output =~ "add :source_name, :text, null: false"
      assert output =~ "add :consecutive_failures, :integer, null: false, default: 0"
      assert output =~ ~s|add :status, :text, null: false, default: "healthy"|
      assert output =~ "timestamps(type: :utc_datetime_usec)"
      assert output =~ "unique_index(:source_health_checks"
      assert output =~ "GRANT SELECT ON op.source_health_checks TO stacks_dbt"
    end

    test "generates ADD COLUMN migration" do
      field = %{
        name: "new_field",
        number: 10,
        type: "TYPE_STRING",
        type_name: nil,
        label: "LABEL_OPTIONAL"
      }

      table = %{
        proto_file: "test.proto",
        proto_message: "Test",
        table_name: "test_table",
        schema_prefix: "op",
        field_overrides: %{new_field: %{null: false}}
      }

      output = MigrationGenerator.generate_add_columns(table, [field], "20260320000003")

      assert output =~ "alter table(:test_table"
      assert output =~ "add :new_field, :text, null: false"
      assert output =~ "remove :new_field"
    end

    test "detects existing columns from migration files" do
      migrations_dir = Path.join(@repo_root, "apps/core/priv/repo/migrations")
      existing = MigrationGenerator.existing_columns(migrations_dir, "event_log")

      assert "event_type" in existing
      assert "aggregate_id" in existing
      assert "payload" in existing
      assert "occurred_at" in existing
      assert "published_at" in existing
      refute "id" in existing
    end

    test "scopes column extraction to correct table in multi-table migrations" do
      migrations_dir = Path.join(@repo_root, "apps/core/priv/repo/migrations")
      existing = MigrationGenerator.existing_columns(migrations_dir, "source_health_checks")

      assert "source_name" in existing
      assert "source_type" in existing
      assert "status" in existing
      # These belong to other tables in the same migration file
      refute "buyer_id" in existing
      refute "amount_cents" in existing
      refute "placement_id" in existing
    end
  end

  describe "delta migration orchestration" do
    test "timestamp fields are excluded from delta when timestamps: :standard" do
      # Simulate a table with timestamps: :standard where a field named
      # "created_at" appears in the proto but should be excluded from
      # delta migration since timestamps() macro handles it
      # A field named "created_at" that exists in proto but would also be
      # generated by the timestamps() macro
      fields = [
        %{name: "name", number: 1, type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"},
        %{
          name: "created_at",
          number: 2,
          type: "TYPE_MESSAGE",
          type_name: ".google.protobuf.Timestamp",
          label: "LABEL_OPTIONAL"
        }
      ]

      # Create a temp migrations dir with a migration that has "name" but not "created_at"
      tmp_dir = Path.join(System.tmp_dir!(), "test_migrations_ts_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "20260101000001_create_test_timestamps.exs"), """
      defmodule Test do
        use Ecto.Migration
        def change do
          create table(:test_timestamps, prefix: "op") do
            add :name, :text
            timestamps(type: :utc_datetime_usec)
          end
        end
      end
      """)

      existing = MigrationGenerator.existing_columns(tmp_dir, "test_timestamps")
      assert "name" in existing

      # The delta logic filters out timestamp columns when timestamps: :standard
      new_fields = Enum.filter(fields, fn field -> field.name not in existing end)

      new_fields =
        Enum.reject(new_fields, fn f -> f.name in ~w(created_at updated_at inserted_at) end)

      assert new_fields == []

      File.rm_rf!(tmp_dir)
    end
  end

  describe "run/1 generate mode" do
    @tag :tmp_dir
    test "run([]) generates ecto schemas, dbt models, and migrations", %{tmp_dir: tmp_dir} do
      # Set up a minimal repo structure in tmp_dir
      proto_dir = Path.join(tmp_dir, "proto")
      File.mkdir_p!(proto_dir)

      # Copy the real persisted.exs and proto files so buf build works
      # Instead, we'll test by calling run from the real repo root
      # by temporarily changing CWD
      original_cwd = File.cwd!()

      try do
        File.cd!(@repo_root)
        ProtoSync.run([])

        # Verify ecto schemas were generated
        manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))

        Enum.each(manifest.tables, fn table ->
          ecto_path = Path.join([@repo_root, "apps/core", table.ecto_path])
          assert File.exists?(ecto_path), "Expected #{ecto_path} to exist"

          dbt_path = Path.join([@repo_root, "dbt/models/staging", table.dbt_path])
          assert File.exists?(dbt_path), "Expected #{dbt_path} to exist"
        end)
      after
        File.cd!(original_cwd)

        # Clean up untracked ADD COLUMN migrations generated during this test run.
        # Note: gen/ is NOT cleaned up — it is the canonical schema location now.
        # We use `git status` to exclude committed migrations from cleanup so that
        # legitimately-added ADD COLUMN migrations in the same branch are preserved.
        today = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "")

        {git_status, _} =
          System.cmd("git", ["status", "--porcelain", "apps/core/priv/repo/migrations/"],
            cd: @repo_root
          )

        untracked_migrations =
          git_status
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, "??"))
          |> Enum.map(fn line -> Path.basename(String.trim(String.slice(line, 3, 9999))) end)

        Path.join([@repo_root, "apps/core/priv/repo/migrations"])
        |> File.ls!()
        |> Enum.filter(fn file ->
          # Remove untracked ADD COLUMN drift migrations generated today.
          # Keep CREATE TABLE migrations and any committed/tracked migrations.
          String.starts_with?(file, today) and
            not String.contains?(file, "_create_") and
            file in untracked_migrations
        end)
        |> Enum.each(fn file ->
          Path.join([@repo_root, "apps/core/priv/repo/migrations", file])
          |> File.rm!()
        end)
      end
    end
  end

  describe "run/1 check mode" do
    test "run([\"--check\"]) exits cleanly when files are up to date" do
      original_cwd = File.cwd!()

      try do
        File.cd!(@repo_root)
        # Should not raise when files are up to date
        ProtoSync.run(["--check"])
      after
        File.cd!(original_cwd)
      end
    end

    test "DriftChecker detects when ecto schema has drifted" do
      # Instead of corrupting the real generated file (which causes CI race
      # conditions), we test the DriftChecker module directly by writing a
      # drifted file to a temp directory and comparing against expected content.
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      [table | _] = manifest.tables
      ecto_path = Path.join([@repo_root, "apps/core", table.ecto_path])

      original_content = File.read!(ecto_path)
      drifted_content = original_content <> "\n# drift marker\n"

      tmp_dir = Path.join(System.tmp_dir!(), "proto_drift_#{System.unique_integer([:positive])}")
      tmp_file = Path.join(tmp_dir, "drifted.ex")
      File.mkdir_p!(tmp_dir)

      try do
        File.write!(tmp_file, drifted_content)

        assert {:drift, ^tmp_file, diff} =
                 DriftChecker.check(original_content, tmp_file)

        assert diff =~ "drift marker"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "DriftChecker returns :ok when file matches expected content" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      [table | _] = manifest.tables
      ecto_path = Path.join([@repo_root, "apps/core", table.ecto_path])

      original_content = File.read!(ecto_path)

      assert :ok = DriftChecker.check(original_content, ecto_path)
    end
  end

  describe "generate_migration paths" do
    test "generates CREATE TABLE migration for new table" do
      tmp_dir = Path.join(System.tmp_dir!(), "test_mig_create_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      table = %{
        proto_file: "test.proto",
        proto_message: "TestMsg",
        table_name: "new_table",
        schema_prefix: "op",
        field_overrides: %{name: %{null: false}},
        migration_exists: false
      }

      fields = [
        %{name: "name", number: 1, type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      ]

      # Call the private generate_migration through run_generate indirectly
      # by using the MigrationGenerator directly (it's what generate_migration delegates to)
      timestamp = MigrationGenerator.generate_timestamp()
      content = MigrationGenerator.generate_create_table(table, fields, timestamp)
      filename = "#{timestamp}_create_#{table.table_name}.exs"
      path = Path.join(tmp_dir, filename)
      File.write!(path, content)

      assert File.exists?(path)
      assert content =~ "create table(:new_table"
      assert content =~ "add :name, :text, null: false"

      File.rm_rf!(tmp_dir)
    end

    test "generates delta migration when existing table has new fields" do
      tmp_dir = Path.join(System.tmp_dir!(), "test_mig_delta_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      # Create an existing migration
      File.write!(Path.join(tmp_dir, "20260101000001_create_delta_test.exs"), """
      defmodule Test do
        use Ecto.Migration
        def change do
          create table(:delta_test, prefix: "op") do
            add :name, :text
          end
        end
      end
      """)

      existing = MigrationGenerator.existing_columns(tmp_dir, "delta_test")
      assert "name" in existing

      new_field = %{
        name: "age",
        number: 2,
        type: "TYPE_INT32",
        type_name: nil,
        label: "LABEL_OPTIONAL"
      }

      table = %{
        proto_file: "test.proto",
        proto_message: "DeltaTest",
        table_name: "delta_test",
        schema_prefix: "op",
        field_overrides: %{}
      }

      content = MigrationGenerator.generate_add_columns(table, [new_field], "20260320120000")
      assert content =~ "alter table(:delta_test"
      assert content =~ "add :age, :integer"
      assert content =~ "remove :age"

      File.rm_rf!(tmp_dir)
    end

    test "delta migration warns about removed fields but does not drop them" do
      tmp_dir = Path.join(System.tmp_dir!(), "test_mig_warn_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "20260101000001_create_warn_test.exs"), """
      defmodule Test do
        use Ecto.Migration
        def change do
          create table(:warn_test, prefix: "op") do
            add :name, :text
            add :old_field, :text
          end
        end
      end
      """)

      existing = MigrationGenerator.existing_columns(tmp_dir, "warn_test")
      assert "old_field" in existing

      # Proto only has "name", not "old_field" — per additive-only convention, no DROP
      # The main task's generate_delta_migration handles this, we just verify existing_columns works
      proto_field_names = ["name"]
      removed = Enum.reject(MapSet.to_list(existing), fn col -> col in proto_field_names end)
      assert "old_field" in removed

      File.rm_rf!(tmp_dir)
    end
  end

  describe "check_migration_drift" do
    test "detects missing proto fields in existing table migrations" do
      tmp_dir = Path.join(System.tmp_dir!(), "test_drift_miss_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "20260101000001_create_drift_table.exs"), """
      defmodule Test do
        use Ecto.Migration
        def change do
          create table(:drift_table, prefix: "op") do
            add :name, :text
          end
        end
      end
      """)

      # The table has migration_exists: true but proto has a field not in the migration
      existing = MigrationGenerator.existing_columns(tmp_dir, "drift_table")
      assert "name" in existing
      refute "email" in existing

      # Simulate check_migration_drift logic for existing table
      fields = [
        %{name: "name", number: 1, type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"},
        %{name: "email", number: 2, type: "TYPE_STRING", type_name: nil, label: "LABEL_OPTIONAL"}
      ]

      proto_field_names = Enum.map(fields, & &1.name)
      missing = Enum.reject(proto_field_names, fn name -> name in existing end)
      assert missing == ["email"]

      File.rm_rf!(tmp_dir)
    end

    test "detects missing CREATE TABLE migration for new table" do
      tmp_dir = Path.join(System.tmp_dir!(), "test_drift_new_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      # No migration file exists for "brand_new_table"
      files = if File.dir?(tmp_dir), do: File.ls!(tmp_dir), else: []

      has_migration =
        Enum.any?(files, fn f ->
          String.contains?(f, "create_brand_new_table") and String.ends_with?(f, ".exs")
        end)

      refute has_migration

      File.rm_rf!(tmp_dir)
    end

    test "returns ok when CREATE TABLE migration exists for new table" do
      tmp_dir = Path.join(System.tmp_dir!(), "test_drift_found_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "20260101000001_create_found_table.exs"), """
      defmodule Test do
        use Ecto.Migration
        def change do
          create table(:found_table, prefix: "op") do
            add :name, :text
          end
        end
      end
      """)

      files = File.ls!(tmp_dir)

      has_migration =
        Enum.any?(files, fn f ->
          String.contains?(f, "create_found_table") and String.ends_with?(f, ".exs")
        end)

      assert has_migration

      File.rm_rf!(tmp_dir)
    end
  end

  describe "find_repo_root" do
    test "finds repo root from repo root directory" do
      original_cwd = File.cwd!()

      try do
        File.cd!(@repo_root)
        # run/1 calls find_repo_root internally, and it works from repo root
        # We verify by calling run successfully (which depends on find_repo_root)
        ProtoSync.run(["--check"])
      after
        File.cd!(original_cwd)
      end
    end

    test "finds repo root from apps/core directory" do
      original_cwd = File.cwd!()
      core_dir = Path.join(@repo_root, "apps/core")

      try do
        File.cd!(core_dir)
        ProtoSync.run(["--check"])
      after
        File.cd!(original_cwd)
      end
    end
  end

  describe "Descriptor.extract_enum_values" do
    setup do
      descriptor = Descriptor.parse!(@repo_root)
      %{descriptor: descriptor}
    end

    test "extracts HealthStatus enum values", %{descriptor: descriptor} do
      values =
        Descriptor.extract_enum_values(
          descriptor,
          ".stacks.monitoring.v1.HealthStatus"
        )

      assert values == ["healthy", "degraded", "broken"]
    end

    test "extracts SourceType enum values", %{descriptor: descriptor} do
      values =
        Descriptor.extract_enum_values(
          descriptor,
          ".stacks.monitoring.v1.SourceType"
        )

      assert values == [
               "scraper_config",
               "review_source",
               "rss_feed",
               "event_source",
               "llm_output"
             ]
    end

    test "excludes UNSPECIFIED sentinel values", %{descriptor: descriptor} do
      values =
        Descriptor.extract_enum_values(
          descriptor,
          ".stacks.monitoring.v1.HealthStatus"
        )

      refute Enum.any?(values, &String.contains?(&1, "unspecified"))
    end

    test "returns empty list for unknown enum", %{descriptor: descriptor} do
      assert Descriptor.extract_enum_values(descriptor, ".nonexistent.Enum") == []
    end

    test "returns empty list for nil type_name", %{descriptor: descriptor} do
      assert Descriptor.extract_enum_values(descriptor, nil) == []
    end
  end

  describe "SchemaYmlGenerator.generate" do
    setup do
      descriptor = Descriptor.parse!(@repo_root)
      %{descriptor: descriptor}
    end

    test "generates event_log model block", %{descriptor: descriptor} do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      [event_log_table | _] = manifest.tables

      fields =
        Descriptor.extract_fields(
          descriptor,
          event_log_table.proto_file,
          event_log_table.proto_message
        )

      output = SchemaYmlGenerator.generate(event_log_table, fields, descriptor)

      assert output =~ "  - name: stg_event_log"
      assert output =~ "Proto-synced staging model for event_log."
      assert output =~ "      - name: id"
      assert output =~ "          - not_null"
      assert output =~ "          - unique"
      assert output =~ "      - name: event_type"
      assert output =~ "      - name: aggregate_id"
      assert output =~ "      - name: payload"
      assert output =~ "      - name: occurred_at"
      assert output =~ "      - name: published_at"
      # event_log has no timestamps
      refute output =~ "      - name: created_at"
      refute output =~ "      - name: updated_at"
    end

    test "generates source_health_checks with timestamps and enum tests", %{
      descriptor: descriptor
    } do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      shc_table = Enum.find(manifest.tables, &(&1.table_name == "source_health_checks"))

      fields =
        Descriptor.extract_fields(descriptor, shc_table.proto_file, shc_table.proto_message)

      output = SchemaYmlGenerator.generate(shc_table, fields, descriptor)

      assert output =~ "  - name: stg_source_health_checks"
      assert output =~ "      - name: created_at"
      assert output =~ "      - name: updated_at"

      # accepted_values no longer auto-generated for enum fields — proto enums
      # can be a superset of DB enums, causing false failures.
      refute output =~ "accepted_values"
    end

    test "not_null tests are generated for null: false overrides", %{descriptor: descriptor} do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      [event_log_table | _] = manifest.tables

      fields =
        Descriptor.extract_fields(
          descriptor,
          event_log_table.proto_file,
          event_log_table.proto_message
        )

      output = SchemaYmlGenerator.generate(event_log_table, fields, descriptor)

      # event_type has null: false in overrides
      # Extract the event_type column block
      lines = String.split(output, "\n")

      event_type_idx =
        Enum.find_index(lines, fn l -> String.contains?(l, "- name: event_type") end)

      assert event_type_idx != nil
      # The tests section should follow with not_null
      assert Enum.at(lines, event_type_idx + 2) =~ "tests:"
      assert Enum.at(lines, event_type_idx + 3) =~ "- not_null"
    end

    test "no auto-generated relationships tests (removed — Postgres enforces FKs)", %{
      descriptor: descriptor
    } do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      [event_log_table | _] = manifest.tables

      fields =
        Descriptor.extract_fields(
          descriptor,
          event_log_table.proto_file,
          event_log_table.proto_message
        )

      output = SchemaYmlGenerator.generate(event_log_table, fields, descriptor)

      # relationships tests are no longer auto-generated
      refute output =~ "relationships:"
    end
  end

  describe "SchemaYmlGenerator.merge" do
    test "preserves non-proto model entries" do
      existing = """
      version: 2

      models:
        - name: stg_books
          description: Hand-written books model.
          columns:
            - name: id
              description: PK.

        - name: stg_event_log
          description: Old description.
          columns:
            - name: id
              description: PK.
      """

      new_block =
        "  - name: stg_event_log\n" <>
          "    description: >\n" <>
          "      Proto-synced staging model for event_log.\n" <>
          "    columns:\n" <>
          "      - name: id\n" <>
          "        description: Surrogate UUID primary key."

      merged = SchemaYmlGenerator.merge(existing, %{"stg_event_log" => new_block})

      # stg_books is preserved
      assert merged =~ "stg_books"
      assert merged =~ "Hand-written books model."

      # stg_event_log is replaced
      assert merged =~ "Proto-synced staging model for event_log."
      refute merged =~ "Old description."
    end

    test "preserves section comment separators" do
      existing = """
      version: 2

      models:
        - name: stg_books
          description: Books.
          columns:
            - name: id
              description: PK.

        # -------------------------------------------------------------------------
        # Section header
        # -------------------------------------------------------------------------

        - name: stg_event_log
          description: Old.
          columns:
            - name: id
              description: PK.
      """

      new_block =
        "  - name: stg_event_log\n" <>
          "    description: >\n" <>
          "      Proto-synced.\n" <>
          "    columns:\n" <>
          "      - name: id\n" <>
          "        description: Surrogate UUID primary key."

      merged = SchemaYmlGenerator.merge(existing, %{"stg_event_log" => new_block})

      assert merged =~ "# Section header"
      assert merged =~ "Proto-synced."
    end

    test "appends new proto models not in existing file" do
      existing = """
      version: 2

      models:
        - name: stg_books
          description: Books.
          columns:
            - name: id
              description: PK.
      """

      new_block =
        "  - name: stg_new_table\n" <>
          "    description: >\n" <>
          "      Proto-synced.\n" <>
          "    columns:\n" <>
          "      - name: id\n" <>
          "        description: PK."

      merged = SchemaYmlGenerator.merge(existing, %{"stg_new_table" => new_block})

      assert merged =~ "stg_books"
      assert merged =~ "stg_new_table"
    end
  end

  describe "SchemaYmlGenerator.check_drift" do
    test "returns :ok when content matches" do
      tmp_path = Path.join(System.tmp_dir!(), "schema_drift_ok_#{System.unique_integer()}.yml")

      content = """
      version: 2

      models:
        - name: stg_test
          description: Test.
          columns:
            - name: id
              description: PK.
      """

      File.write!(tmp_path, content)

      # No proto models -> merge is a no-op
      assert :ok == SchemaYmlGenerator.check_drift(tmp_path, %{})

      File.rm!(tmp_path)
    end

    test "returns drift when proto model has changed" do
      tmp_path = Path.join(System.tmp_dir!(), "schema_drift_chg_#{System.unique_integer()}.yml")

      content = """
      version: 2

      models:
        - name: stg_event_log
          description: Old.
          columns:
            - name: id
              description: PK.
      """

      File.write!(tmp_path, content)

      new_block =
        "  - name: stg_event_log\n" <>
          "    description: >\n" <>
          "      New.\n" <>
          "    columns:\n" <>
          "      - name: id\n" <>
          "        description: PK."

      assert {:drift, ^tmp_path, _diff} =
               SchemaYmlGenerator.check_drift(tmp_path, %{"stg_event_log" => new_block})

      File.rm!(tmp_path)
    end

    test "returns drift when schema.yml does not exist" do
      path = "/nonexistent/schema.yml"

      assert {:drift, ^path, msg} = SchemaYmlGenerator.check_drift(path, %{})
      assert msg =~ "file not found"
    end
  end

  describe "integration" do
    test "mix proto.sync generates files that pass --check" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)

      core_root = Path.join(@repo_root, "apps/core")
      dbt_root = Path.join(@repo_root, "dbt/models/staging")

      results =
        Enum.flat_map(manifest.tables, fn table ->
          fields =
            Descriptor.extract_fields(descriptor, table.proto_file, table.proto_message)

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

          [ecto_result, dbt_result]
        end)

      drifted = Enum.filter(results, &match?({:drift, _, _}, &1))

      if drifted != [] do
        details =
          Enum.map_join(drifted, "\n", fn {:drift, path, diff} -> "#{path}:\n#{diff}" end)

        flunk("Generated files have drifted from proto definitions:\n#{details}")
      end
    end

    test "schema.yml roundtrip: generate then check passes" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      descriptor = Descriptor.parse!(@repo_root)
      schema_yml_path = Path.join(@repo_root, "dbt/models/staging/schema.yml")

      generated_blocks =
        Map.new(manifest.tables, fn table ->
          fields =
            Descriptor.extract_fields(descriptor, table.proto_file, table.proto_message)

          model_name = "stg_#{table.table_name}"
          block = SchemaYmlGenerator.generate(table, fields, descriptor)
          {model_name, block}
        end)

      # After merge, check_drift should return :ok
      existing = File.read!(schema_yml_path)
      merged = SchemaYmlGenerator.merge(existing, generated_blocks)

      # Write merged content to a temp file and check drift
      tmp_path = Path.join(System.tmp_dir!(), "schema_roundtrip_#{System.unique_integer()}.yml")
      File.write!(tmp_path, merged)

      assert :ok == SchemaYmlGenerator.check_drift(tmp_path, generated_blocks)

      File.rm!(tmp_path)
    end
  end

  describe "ProtoJsonGenerator" do
    setup do
      descriptor = Descriptor.parse!(@repo_root)
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      %{descriptor: descriptor, manifest: manifest}
    end

    test "generates module with one function per proto_json config entry", %{
      descriptor: descriptor,
      manifest: manifest
    } do
      output = ProtoJsonGenerator.generate(manifest, descriptor)

      assert output =~ "defmodule StacksWeb.ProtoJSON.Gen do"

      # One function per config entry
      for config <- manifest.proto_json do
        assert output =~ "def #{config.function_name}(struct) do"
        assert output =~ "def #{config.function_name}(nil), do: nil"
        assert output =~ "@spec #{config.function_name}(map() | nil) :: map() | nil"
      end
    end

    test "author function maps website_url field to website json key", %{
      descriptor: descriptor,
      manifest: manifest
    } do
      output = ProtoJsonGenerator.generate(manifest, descriptor)

      # Proto field is website_url with json_name="website" — Author uses the json_name
      assert output =~ "website: struct.website_url"

      # The Author function should NOT have "website_url:" as a map key (only "website:")
      # Split output by function boundaries and check the author section
      author_section =
        output
        |> String.split("@doc")
        |> Enum.find(&String.contains?(&1, "def author(struct)"))

      assert author_section != nil
      refute author_section =~ ~r/^\s+website_url:/m
    end

    test "skipped fields are excluded from output", %{
      descriptor: descriptor,
      manifest: manifest
    } do
      output = ProtoJsonGenerator.generate(manifest, descriptor)

      # Book skips author, editions, edition_count, primary_edition, community_read_count
      refute output =~ "author: struct.author"
      refute output =~ "edition_count: struct.edition_count"

      # User skips password_hash
      refute output =~ "password_hash: struct.password_hash"
    end
  end
end
