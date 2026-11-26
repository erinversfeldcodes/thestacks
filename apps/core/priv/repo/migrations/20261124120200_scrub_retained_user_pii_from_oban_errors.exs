defmodule Core.Repo.Migrations.ScrubRetainedUserPiiFromObanErrors do
  @moduledoc """
      A worker that raised with a %User{} argument wrote the Argon2 password_hash,
      the email address and one-time auth tokens into public.oban_jobs.errors,
      where they were retained outside the erasure path. The redacting inspector
      added alongside this migration prevents it at the source; this scrubs the
      rows that already hold it.

      An errors array whose text mentions `password_hash` carries a dumped
      credential, so it is emptied. Losing the error history of an
      already-failed job is a fair price for removing a retained secret, and a
      failure recorded after the redaction no longer matches the filter.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    UPDATE public.oban_jobs
       SET errors = '{}'::jsonb[]
     WHERE errors::text LIKE '%password_hash%'
    """)
  end

  def down do
    # Irreversible by design: the scrubbed text held a retained secret and is
    # not restored.
    :ok
  end
end
