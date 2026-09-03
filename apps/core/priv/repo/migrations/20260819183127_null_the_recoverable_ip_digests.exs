defmodule Core.Repo.Migrations.NullTheRecoverableIpDigests do
  @moduledoc """
      Clears every `ip_address` already stored on `audit.audit_log`.

      The column held a bare, unkeyed SHA-256 of the client IP. That is
      pseudonymisation, not anonymisation: the IPv4 space is 2^32, so the whole
      of it inverts by exhaustion in about an hour on one core, and a single /16
      falls in a fraction of a second. Anyone holding the column held recoverable
      network identifiers — including for people who had asked to be erased,
      because this table is retained past erasure by design.

      These values cannot be migrated to a keyed digest: the plaintext is gone,
      so there is nothing to re-derive from. Leaving them would keep a
      recoverable population sitting behind a column that merely looks hashed,
      and would leave a silent mix of old-scheme and new-scheme values that a
      future equality check would quietly get wrong. So they are cleared.

      What is lost is the ability to correlate historical rows by origin IP.
      That is the point: correlation by origin is exactly the capability the
      values should not have carried in this form.

      ⛔ The table's append-only trigger refuses UPDATE unless
      `app.audit_gdpr_erasure` is set, and a statement-level trigger disarms it
      the moment one UPDATE completes. That is why this is a single statement
      over the whole table rather than a batched loop — a second statement would
      be blocked by the trigger it just disarmed.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL app.audit_gdpr_erasure = 'true'")
    execute("UPDATE audit.audit_log SET ip_address = NULL WHERE ip_address IS NOT NULL")
  end

  def down do
    # Irreversible by construction: the digests are not recoverable from the
    # nulled column, and the plaintext they were derived from was never stored.
    :ok
  end
end
