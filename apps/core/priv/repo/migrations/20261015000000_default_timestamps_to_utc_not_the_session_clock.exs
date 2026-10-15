defmodule Core.Repo.Migrations.DefaultTimestampsToUtcNotTheSessionClock do
  @moduledoc """
      Eight columns default to `now()` while being typed `timestamp without time
      zone`, so each one writes the SESSION's local time, not UTC.

      `now()` returns `timestamptz`. Assigning it to a naive column casts it
      through the connection's `TimeZone` GUC, which drops the offset after
      shifting the value. The application then reads every one of these columns
      as `:utc_datetime_usec` — a naive timestamp interpreted as UTC. So on any
      connection whose `TimeZone` is not UTC the stored value is wrong by the
      offset, silently and in a direction that depends on geography:

          set TimeZone='Africa/Johannesburg';
          select now()::timestamp - (now() at time zone 'utc');
          --  02:00:00

      Latent rather than live: local and CI Postgres both report `Etc/UTC`, and
      most writers pass a timestamp explicitly rather than relying on the
      default. But a default exists for the writer who does NOT pass one, and
      that is exactly the writer who will not notice the clock is wrong.

      ## Why this is worth a migration rather than a note

      `library_import_rows.created_at` is a RETENTION clock over free text a
      reader wrote — Goodreads reviews, private notes — and the warehouse has no
      erasure path. East of UTC the default stamps a row into the future, which
      pushes it LATER into the 30-day sweep window and so EXTENDS how long that
      text is kept. The migration that added the default claims the opposite in
      its own moduledoc: that its repair "can only age a row EARLIER into the
      sweep window — never later, so no row's retention is extended". That
      guarantee is true of the backfill and false of the default it set
      alongside.

      `feedback_entries.created_at` and `post_comments.created_at` are the same
      shape — reader free text on a retention-relevant clock.

      ## Class, not instance

      Eight columns share the defect and all eight are fixed here, because
      fixing only the retention clock would leave seven identical traps reading
      as though they had been considered. `audit.audit_log.occurred_at` is
      included even though `Stacks.Audit.log/3` always passes `occurred_at`
      explicitly: an append-only audit log is the last place to leave a clock
      that depends on who connected.

      Metadata only — `SET DEFAULT` rewrites no rows, takes no lock worth
      naming, and is idempotent by definition, so this is re-runnable as it
      stands. Existing rows are NOT rewritten: a row already written through a
      non-UTC session keeps its skewed value, and there is no way to tell those
      apart from correct ones after the fact. Nothing is claimed about them.
  """
  use Ecto.Migration

  # {schema, table, column}
  @columns [
    {"op", "event_log", "occurred_at"},
    {"op", "feedback_entries", "created_at"},
    {"op", "group_members", "joined_at"},
    {"op", "library_import_rows", "created_at"},
    {"op", "partner_inventory", "synced_at"},
    {"op", "post_comments", "created_at"},
    {"op", "shelves", "created_at"},
    {"audit", "audit_log", "occurred_at"}
  ]

  def up do
    for {schema, table, column} <- @columns do
      execute("""
      ALTER TABLE #{schema}.#{table}
        ALTER COLUMN #{column} SET DEFAULT (now() AT TIME ZONE 'utc')
      """)
    end
  end

  def down do
    # Restores the session-clock default. Reversible because a migration should
    # be, not because reverting is advisable.
    for {schema, table, column} <- @columns do
      execute("""
      ALTER TABLE #{schema}.#{table}
        ALTER COLUMN #{column} SET DEFAULT now()
      """)
    end
  end
end
