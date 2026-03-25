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
    },
    %{
      proto_file: "stacks/common/v1/book.proto",
      proto_message: "Book",
      table_name: "books",
      schema_prefix: "op",
      ecto_module: Stacks.Books.Book,
      ecto_path: "lib/stacks/gen/books/book.ex",
      dbt_path: "stg_books.sql",
      timestamps: :standard,
      migration_exists: true,
      dbt_grant: true,
      indexes: [],
      associations: [
        {:has_many, :editions, Stacks.Books.BookEdition, foreign_key: :book_id}
      ],
      field_overrides: %{
        # DB fields
        title: %{null: false},
        author_id: %{belongs_to: Stacks.Books.Author},
        subjects: %{ecto_type: {:array, :string}, default: []},
        bisac_codes: %{ecto_type: {:array, :string}, default: []},
        visibility_tier: %{default: "public"},
        # API-only fields — not DB columns
        author: %{skip: true},
        editions: %{skip: true},
        edition_count: %{skip: true},
        primary_edition: %{skip: true},
        community_read_count: %{skip: true}
      }
    }
  ]
}
