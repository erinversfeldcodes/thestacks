defmodule Core.Repo.Migrations.AddPublicToVisibilityLevel do
  @moduledoc """
  Adds `public` to the `op.visibility_level` enum (#225) — the top rung of the
  Audience ladder: "anyone with the link, signed in or not". Storage-only; the
  read-access split (platform = signed-in, public = anyone) is enforced in
  `Stacks.Visibility`. Public content stays `noindex` (anon-readable, not crawled).

  `ALTER TYPE … ADD VALUE` cannot run inside a migration transaction, hence
  `@disable_ddl_transaction`. Enum values are append-only and cannot be dropped,
  so `down/0` is a no-op (leaving the label in place is harmless — nothing stores it
  once the app-layer vocabulary no longer offers it).
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("ALTER TYPE op.visibility_level ADD VALUE IF NOT EXISTS 'public' AFTER 'platform'")
  end

  def down do
    # Postgres cannot remove an enum value; intentionally a no-op.
    :ok
  end
end
