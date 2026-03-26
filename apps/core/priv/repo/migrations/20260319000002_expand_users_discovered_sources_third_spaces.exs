defmodule Core.Repo.Migrations.ExpandUsersDiscoveredSourcesThirdSpaces do
  @moduledoc """
  Adds notification/onboarding columns to op.users, opt-out columns to
  op.third_spaces, exclusion columns to op.discovered_sources, and extends
  the source_status enum with an 'excluded' value.

  ALTER TYPE … ADD VALUE cannot run inside a transaction, so DDL transactions
  are disabled for this migration.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:users, prefix: "op") do
      add_if_not_exists :onboarding_completed, :boolean, default: false, null: false
      add_if_not_exists :notify_wishlist_availability, :boolean, default: false, null: false
      add_if_not_exists :notify_marketplace, :boolean, default: true, null: false
      add_if_not_exists :notify_group_invitations, :boolean, default: true, null: false
      add_if_not_exists :notify_event_matches, :boolean, default: false, null: false
    end

    alter table(:third_spaces, prefix: "op") do
      add_if_not_exists :opted_out, :boolean, default: false, null: false
      add_if_not_exists :opted_out_at, :utc_datetime_usec
    end

    alter table(:discovered_sources, prefix: "op") do
      add_if_not_exists :excluded_at, :utc_datetime_usec
      add_if_not_exists :exclusion_email, :text
    end

    execute("ALTER TYPE op.source_status ADD VALUE IF NOT EXISTS 'excluded'")
  end

  def down do
    alter table(:users, prefix: "op") do
      remove :onboarding_completed
      remove :notify_wishlist_availability
      remove :notify_marketplace
      remove :notify_group_invitations
      remove :notify_event_matches
    end

    alter table(:third_spaces, prefix: "op") do
      remove :opted_out
      remove :opted_out_at
    end

    alter table(:discovered_sources, prefix: "op") do
      remove :excluded_at
      remove :exclusion_email
    end

    # NOTE: ALTER TYPE ... ADD VALUE cannot be reversed in PostgreSQL — enum values
    # cannot be removed once added. The 'excluded' value in op.source_status is
    # intentionally left in place on rollback to avoid a destructive DDL operation.
  end
end
