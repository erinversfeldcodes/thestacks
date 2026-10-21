defmodule Core.Repo.Migrations.MakeTheDefinerGrantAsNarrowAsItWasDocumentedToBe do
  @moduledoc """
      Three `SECURITY DEFINER` functions answer cross-user questions that
      per-user row-level scoping cannot. Their safety argument is that each
      returns one narrow answer and is reachable only by the roles that need
      it.

      ⛔ **The second half of that argument was not true.** Postgres grants
      `EXECUTE` on a new function to `PUBLIC` by default, and nothing revoked
      it, so the explicit grants to the application role were decorative and
      every role that can connect could call all three. Measured on a real
      database: as the application role, with no scope set,
      `op.placement_owners_for_edition` returned three user ids — while the
      same question asked directly against the table was refused by the very
      policy these functions exist to work around.

      ⚠️ This was not a regression — before the scoping change the application
      role could read those tables outright. It is worse than a regression in
      one specific way: the narrow grant is the entire justification for
      keeping three privileged reads at all, and a reviewer reading the grant
      list would have concluded a boundary existed where none did.

      ## What each function is for, and who therefore needs it

      - `op.blocked_pair/2` — the authorisation gate, four call sites in the
        application. The application role needs it.
      - `op.wishlist_user_ids/1` — availability notifications, raised from the
        application. The application role needs it.
      - `op.placement_owners_for_edition/1` — a data correction that runs on
        the owner connection, never on a request. **The application role does
        not need it and never called it**; it was reachable only through the
        default grant.

      `REVOKE … FROM PUBLIC` then grant by name, so the list that reads like an
      allowlist is one.
  """

  use Ecto.Migration

  @app_functions ["op.blocked_pair(uuid, uuid)", "op.wishlist_user_ids(uuid)"]
  @owner_only_functions ["op.placement_owners_for_edition(uuid)"]

  def up do
    for fun <- @app_functions ++ @owner_only_functions do
      execute("REVOKE ALL ON FUNCTION #{fun} FROM PUBLIC")
    end

    for fun <- @app_functions do
      execute("GRANT EXECUTE ON FUNCTION #{fun} TO stacks_app")
    end

    # ⚠️ Nothing is granted for the owner-only function. It is called on the
    # connection that owns it, which needs no grant, and naming no role here is
    # the point rather than an omission.
  end

  def down do
    # Restoring the default grant restores the hole this migration closed, so
    # it is restored explicitly and only on the two the application calls.
    for fun <- @app_functions ++ @owner_only_functions do
      execute("GRANT EXECUTE ON FUNCTION #{fun} TO PUBLIC")
    end
  end
end
