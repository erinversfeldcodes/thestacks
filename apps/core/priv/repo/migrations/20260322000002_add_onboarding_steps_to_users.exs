defmodule Core.Repo.Migrations.AddOnboardingStepsToUsers do
  @moduledoc """
  Replaces the boolean `onboarding_completed` column with a JSONB `onboarding_steps`
  column and a GENERATED ALWAYS AS computed `onboarding_completed` boolean.

  The generated column stays true only when all three steps (profile, age_verification,
  privacy) are individually set to true in the JSON object.

  The staging.stg_users view depends on `onboarding_completed`, so the migration drops
  and recreates it around the column swap.
  """

  use Ecto.Migration

  # Recreated after each column swap. The DO block guards on schema existence so
  # the migration is a no-op in the test database (which has no staging schema).
  @recreate_stg_users_view """
  DO $body$
  BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'staging') THEN
      CREATE OR REPLACE VIEW staging.stg_users AS
      SELECT
        id, email, display_name, role, country_code, city,
        consent_analytics, age_verified, profile_visibility,
        website_url, consent_analytics_at, onboarding_completed,
        notify_wishlist_availability, notify_marketplace,
        notify_group_invitations, notify_event_matches,
        email_confirmed, age_verified_at, age_verification_provider,
        onboarding_steps, created_at, updated_at
      FROM op.users;
    END IF;
  END $body$;
  """

  def up do
    alter table(:users, prefix: "op") do
      add_if_not_exists :onboarding_steps, :map, default: %{}, null: false
    end

    execute("""
    DO $body$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'op' AND table_name = 'users'
          AND column_name = 'onboarding_completed'
          AND is_generated = 'NEVER'
      ) THEN
        DROP VIEW IF EXISTS staging.stg_users CASCADE;

        ALTER TABLE op.users DROP COLUMN onboarding_completed;

        ALTER TABLE op.users
          ADD COLUMN onboarding_completed boolean GENERATED ALWAYS AS (
            (onboarding_steps->>'profile')::boolean IS TRUE
            AND (onboarding_steps->>'age_verification')::boolean IS TRUE
            AND (onboarding_steps->>'privacy')::boolean IS TRUE
          ) STORED;
      END IF;
    END $body$;
    """)

    execute(@recreate_stg_users_view)
  end

  def down do
    execute("""
    DO $body$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'op' AND table_name = 'users'
          AND column_name = 'onboarding_completed'
          AND is_generated = 'ALWAYS'
      ) THEN
        DROP VIEW IF EXISTS staging.stg_users CASCADE;

        ALTER TABLE op.users DROP COLUMN onboarding_completed;

        ALTER TABLE op.users
          ADD COLUMN onboarding_completed boolean NOT NULL DEFAULT false;
      END IF;
    END $body$;
    """)

    execute(@recreate_stg_users_view)

    alter table(:users, prefix: "op") do
      remove_if_exists :onboarding_steps, :map
    end
  end
end
