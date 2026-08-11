defmodule Core.Repo.Migrations.BackfillAndConstrainUserHandles do
  @moduledoc """
  Companion to the proto-generated `add :handle` migration (#211). Backfills a
  handle for every existing user and makes the column NOT NULL so every user
  always has a reachable `/u/:handle`. The case-insensitive uniqueness index is
  built separately and CONCURRENTLY in `20260714200520` so it never holds a
  write-blocking lock on `op.users` (the auth hot-path table).

  Backfill = slug(display_name, ≤20 chars, non-alnum→'_', trimmed; 'reader' when
  empty) + '_' + 6 hex chars keyed by md5(random || id). The random suffix makes a
  collision astronomically unlikely, so no dedupe pass is needed; the unique index
  is the backstop. This mirrors `Stacks.Accounts.generate_handle/1` used at
  registration.
  """
  use Ecto.Migration

  @breaking_ok "handle is new this release; app writes it on every insert (Accounts.maybe_put_handle) and the backfill fills all existing rows, so the column is never null when tightened. #218 tracks deferring the tighten if the table reaches rolling prod."

  def up do
    execute("""
    UPDATE op.users
    SET handle =
      coalesce(
        nullif(
          substr(
            trim(both '_' from regexp_replace(
              lower(coalesce(nullif(trim(display_name), ''), 'reader')),
              '[^a-z0-9]+', '_', 'g'
            )),
            1, 20
          ),
          ''
        ),
        'reader'
      ) || '_' || substr(md5(random()::text || id::text), 1, 6)
    WHERE handle IS NULL
    """)

    alter table(:users, prefix: "op") do
      modify :handle, :text, null: false
    end
  end

  def down do
    alter table(:users, prefix: "op") do
      modify :handle, :text, null: true
    end
  end
end
