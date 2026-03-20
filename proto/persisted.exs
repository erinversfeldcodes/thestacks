%{
  version: 1,
  tables: [
    %{
      proto_file: "stacks/internal/v1/event_bus.proto",
      proto_message: "EventEnvelope",
      table_name: "event_log",
      schema_prefix: "op",
      ecto_module: Stacks.Events.EventLog,
      ecto_path: "lib/stacks/gen/events/event_log.ex",
      dbt_path: "stg_event_log.sql",
      timestamps: false,
      migration_exists: true,
      dbt_grant: true,
      indexes: [
        %{
          name: "idx_event_log_type_agg",
          columns: [:event_type, :aggregate_id, {:desc, :occurred_at}]
        }
      ],
      field_overrides: %{
        aggregate_id: %{ecto_type: :binary_id, null: false},
        event_type: %{null: false},
        aggregate_type: %{null: false},
        payload: %{ecto_type: :map, null: false},
        metadata: %{ecto_type: :map, null: false, default: {:fragment, "'{}'::jsonb"}},
        schema_version: %{default: 1, null: false},
        occurred_at: %{null: false, default: {:fragment, "NOW()"}}
      }
    },
    %{
      proto_file: "stacks/monitoring/v1/source_health_check.proto",
      proto_message: "SourceHealthCheck",
      table_name: "source_health_checks",
      schema_prefix: "op",
      ecto_module: Stacks.Monitoring.SourceHealthCheck,
      ecto_path: "lib/stacks/gen/monitoring/source_health_check.ex",
      dbt_path: "stg_source_health_checks.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [
        %{
          name: "source_health_checks_source_name_index",
          columns: [:source_name],
          unique: true
        }
      ],
      field_overrides: %{
        source_name: %{null: false},
        source_type: %{null: false},
        consecutive_failures: %{default: 0, null: false},
        total_successes: %{default: 0, null: false},
        total_failures: %{default: 0, null: false},
        status: %{default: "healthy", null: false}
      }
    }
  ]
}
