defmodule Mix.Tasks.Proto.SyncTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ProtoSync.DbtGenerator
  alias Mix.Tasks.ProtoSync.Descriptor
  alias Mix.Tasks.ProtoSync.DriftChecker
  alias Mix.Tasks.ProtoSync.EctoGenerator
  alias Mix.Tasks.ProtoSync.Manifest
  alias Mix.Tasks.ProtoSync.MigrationGenerator
  alias Mix.Tasks.ProtoSync.TypeMapper

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "Manifest" do
    test "loads valid manifest" do
      manifest = Manifest.load!(Path.join(@repo_root, "proto/persisted.exs"))
      assert manifest.version == 1
      assert [event_log, _] = manifest.tables
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

      assert_raise RuntimeError, ~r/Unknown message type/, fn ->
        TypeMapper.ecto_type(field)
      end
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
      [_, shc_table] = manifest.tables

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
      [_, shc_table] = manifest.tables

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
      assert output =~ ~s|add :metadata, :map, null: false, default: fragment("'{}'::jsonb")|

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
      [_, shc_table] = manifest.tables

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
  end
end
