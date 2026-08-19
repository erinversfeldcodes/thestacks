defmodule Core.Repo.Migrations.RevokeAdminSessionsPinnedToUnkeyedIpDigests do
  @moduledoc """
      Revokes every live admin session whose `ip_hash` was computed with the old
      unkeyed digest.

      The digest is now keyed (`Stacks.IPDigest`), so a stored unkeyed value can
      never again equal a freshly computed one. `SessionContext.get_valid/2`
      would answer `{:error, :ip_mismatch}` for those sessions anyway — this
      migration makes that explicit rather than leaving rows that look live and
      behave revoked.

      Revoking rather than nulling is deliberate. `ip_hash` is `NOT NULL` and it
      is the session-pinning check: a null would either fail the constraint or,
      worse, turn the comparison into one no address can satisfy while the row
      still advertises itself as valid. Revocation says the true thing — these
      sessions are over — and the operator simply signs in again, which mints a
      row carrying a keyed digest.

      Old rows keep their unkeyed `ip_hash` value. That is acceptable where the
      audit trail's was not: an admin session is short-lived and already carries
      `expires_at`, so this population drains on its own, whereas audit rows are
      retained past erasure and would have kept a recoverable identifier forever.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE op.admin_sessions
       SET revoked_at = NOW()
     WHERE revoked_at IS NULL
    """)
  end

  def down do
    # Un-revoking would restore sessions whose pinning check cannot pass.
    :ok
  end
end
