defmodule Core.Repo.Migrations.DropAgeVerificationOnboardingStep do
  @moduledoc """
  ADR-020: the self-declared "verify your age" onboarding step is removed.

  The `onboarding_completed` GENERATED ALWAYS AS column previously required all
  three steps (profile, age_verification, privacy). With the age-verification
  step dropped from the application step list, that column would become
  permanently unsatisfiable (the `age_verification` key is never written), so it
  is redefined here to require only the two surviving steps: profile + privacy.

  A generated column's expression cannot be `ALTER`ed in place, so the column is
  dropped and re-added. The staging.stg_users view depends on it, so it is
  dropped and recreated around the swap (guarded on schema existence — a no-op in
  the test DB, which has no staging schema).
  """

  use Ecto.Migration

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

  def up, do: swap_generated_column(with_age_verification: false)

  def down, do: swap_generated_column(with_age_verification: true)

  defp swap_generated_column(with_age_verification: include_age?) do
    age_clause =
      if include_age?,
        do: "AND (onboarding_steps->>'age_verification')::boolean IS TRUE",
        else: ""

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
          ADD COLUMN onboarding_completed boolean GENERATED ALWAYS AS (
            (onboarding_steps->>'profile')::boolean IS TRUE
            #{age_clause}
            AND (onboarding_steps->>'privacy')::boolean IS TRUE
          ) STORED;
      END IF;
    END $body$;
    """)

    execute(@recreate_stg_users_view)
  end
end
