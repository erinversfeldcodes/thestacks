defmodule StacksWeb.SessionTeardown do
  @moduledoc """
      Ending the caller's session server-side, for the two paths that end one.

      ⛔ WHY THIS IS A MODULE AND NOT TWO COPIES. `AuthController.logout/2` did
      this correctly — revoke the presented token, revoke its family, clear the
      cookie — and `GDPRController.delete_account/2` did none of it, returning
      202 while the browser kept a credential for the account it had just asked
      to erase. Two paths end a session; one knew how. Copying the sequence into
      the second would have left the next path to copy it again, and the
      divergence would be invisible because each copy reads correct on its own.

      ⚖️ **This is NOT the erasure guarantee, and conflating the two is the
      mistake to avoid.** `Stacks.GDPR.Deletion`'s `:revoke_sessions` step
      already re-counts `op.guardian_tokens` after the delete and FAILS the whole
      erasure if any row survives, so the token is gone whether or not this
      module runs. What this fixes is the window before the Oban job runs, and
      the reader's own browser: without it they carry a cookie that looks live
      until their next request is refused.

      ⚠️ So the severity is a UX one, not a data-protection breach — nothing can
      be read with that cookie once the job has run, and the job is what the
      regulation cares about. Recorded here because the issue this came from was
      filed as a live-session breach, and a future reader deleting this module on
      the strength of `:revoke_sessions` would be half right: the erasure stays
      correct, and the stale cookie comes back.
  """

  require Logger

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias StacksWeb.Plugs.SessionCookie

  @doc """
      Revoke the presented token and its family, then clear the session cookie.

      ⚠️ Returns the `conn` with the cookie cleared but does NOT send a response:
      the two callers answer differently (204 for a sign-out, 202 for a queued
      erasure) and the status is theirs to choose.

      ⛔ A REVOCATION FAILURE IS LOGGED, NOT RAISED, and that is deliberate in
      both callers' cases. The client must consider itself signed out either way
      — telling a reader their sign-out failed leaves them on a page that claims
      they are signed in — but a failure means the token stays valid until its
      TTL, which is worth investigating rather than discarding. For the erasure
      path there is a second net underneath: `:revoke_sessions` will fail the
      whole job if the row survives.
  """
  @type scope :: :this_device | :everywhere

  @spec end_session(Plug.Conn.t(), scope()) :: Plug.Conn.t()
  def end_session(conn, scope) when scope in [:this_device, :everywhere] do
    token = Guardian.Plug.current_token(conn)
    claims = Guardian.Plug.current_claims(conn) || %{}

    revoke_presented_token(token)
    revoke_family(claims)
    revoke_other_devices(scope, conn)

    SessionCookie.delete_session_cookie(conn)
  end

  # ⛔ THE SCOPE IS AN ARGUMENT BECAUSE FORGETTING IT IS SILENT. The password
  # change must end EVERY session; sign-out must end only this one. Both revoke
  # the caller's own token, so a test that re-presents the caller's credential
  # cannot tell them apart — which is exactly how `revoke_all_user_sessions/1`
  # was once dropped from the password path with every test still green.
  #
  # ⚖️ A parameter rather than two functions: the difference is one clause, and
  # two functions differing by one line is how the second one drifts. As a value
  # it is also something a test can assert per caller.
  defp revoke_other_devices(:this_device, _conn), do: :ok

  defp revoke_other_devices(:everywhere, conn) do
    case Guardian.Plug.current_resource(conn) do
      %{id: user_id} -> Accounts.revoke_all_user_sessions(user_id)
      _ -> :ok
    end

    :ok
  end

  defp revoke_presented_token(nil), do: :ok

  defp revoke_presented_token(token) do
    case Guardian.revoke(token) do
      {:ok, _claims} ->
        :ok

      error ->
        Logger.warning("Guardian.revoke failed on session teardown: #{inspect(error)}")
        :ok
    end
  end

  # ⚠️ The family, not just the token. A refresh mints a sibling from the same
  # `family_id`; revoking only the presented one leaves every sibling live, which
  # on the erasure path means a credential for an account being deleted.
  defp revoke_family(%{"family_id" => family_id}) when is_binary(family_id) do
    Accounts.revoke_token_family(family_id)
    :ok
  end

  defp revoke_family(_claims), do: :ok
end
