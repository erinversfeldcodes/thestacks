defmodule Core.Repo.Migrations.BackfillAndConstrainUserHandles do
  @moduledoc """
  Companion to the proto-generated `add :handle` migration (#211). Backfills a
  handle for every existing user, adds the case-insensitive uniqueness index, and
  makes the column NOT NULL so every user always has a reachable `/u/:handle`.

  Backfill = slug(display_name, ≤20 chars, non-alnum→'_', trimmed; 'reader' when
  empty) + '_' + 6 hex chars keyed by md5(random || id). The random suffix makes a
  collision astronomically unlikely, so no dedupe pass is needed; the unique index
  is the backstop. This mirrors `Stacks.Accounts.generate_handle/1` used at
  registration.
  """
  use Ecto.Migration

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

    create unique_index(:users, ["lower(handle)"],
             prefix: "op",
             name: :users_lower_handle_index
           )

    execute("ALTER TABLE op.users ALTER COLUMN handle SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE op.users ALTER COLUMN handle DROP NOT NULL")

    drop_if_exists index(:users, ["lower(handle)"],
                     prefix: "op",
                     name: :users_lower_handle_index
                   )
  end
end
