defmodule Stacks.GDPR.Deletion do
  @moduledoc """
  GDPR right-to-erasure. Deletes all operational data for a user.

  All operations run in a single `Ecto.Multi` transaction to ensure atomicity.
  A deletion record is inserted into the audit_log after all data is removed.

  The event_log is NOT modified. Event payloads contain no real-world PII
  (name, email, etc.) — only opaque UUIDs and system metadata — so there is
  nothing to scrub. The audit trail is preserved intact.
  """

  # Ecto.Multi uses an opaque MapSet internally; dialyzer cannot resolve the
  # opaque subterms after Multi.new() and fires call_without_opaque on every
  # chained call. This is a known false positive.
  @dialyzer :no_opaque

  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.User
  alias Stacks.Audit
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  @doc """
  Deletes all operational data for a user.
  Returns `{:ok, map()}` on success.
  """
  @spec delete_user_data(binary()) :: {:ok, map()} | {:error, atom(), term(), map()}
  def delete_user_data(user_id) do
    Multi.new()
    |> Multi.run(:set_gdpr_guc, fn repo, _ ->
      repo.query!("SET LOCAL app.audit_gdpr_erasure = 'true'")
      {:ok, :set}
    end)
    |> Multi.run(:bookshelves, fn repo, _ ->
      bookshelves = repo.all(from bs in Bookshelf, where: bs.user_id == ^user_id)
      {:ok, bookshelves}
    end)
    |> Multi.run(:bookshelf_ids, fn _repo, %{bookshelves: bookshelves} ->
      {:ok, Enum.map(bookshelves, & &1.id)}
    end)
    |> Multi.run(:delete_history, fn repo, %{bookshelf_ids: bookshelf_ids} ->
      # PlacementHistory has from_bookshelf/to_bookshelf UUIDs, not placement_id
      {count, _} =
        repo.delete_all(
          from h in PlacementHistory,
            where: h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids
        )

      {:ok, count}
    end)
    |> Multi.run(:delete_placements, fn repo, %{bookshelf_ids: bookshelf_ids} ->
      {count, _} = repo.delete_all(from p in Placement, where: p.bookshelf_id in ^bookshelf_ids)
      {:ok, count}
    end)
    |> Multi.run(:delete_bookshelves, fn repo, _ ->
      {count, _} = repo.delete_all(from bs in Bookshelf, where: bs.user_id == ^user_id)
      {:ok, count}
    end)
    |> Multi.run(:delete_user, fn repo, _ ->
      case repo.get(User, user_id) do
        nil -> {:error, :user_not_found}
        user -> repo.delete(user)
      end
    end)
    |> Multi.run(:revoke_sessions, fn repo, _ ->
      # Kill every live auth session belonging to the erased user. Neither
      # op.auth_token_families (no FK on user_id) nor op.guardian_tokens
      # (schemaless; `sub` is a plain string, not an FK) cascades from the
      # user delete, so without this step a hard-deleted user's access token
      # keeps passing verify_claims for up to its 8h TTL and their session
      # rows linger indefinitely.
      #
      # We DELETE the rows rather than mark `revoked_at`: this is an ERASURE,
      # so the goal is full removal of the user's identifiers. Marking revoked
      # would leave rows still keyed to the deleted user's UUID forever, which
      # contradicts the right-to-erasure intent; deletion also achieves the
      # same security outcome (the family vanishes ⇒ verify_claims fails
      # closed, and the guardian_tokens row is gone ⇒ the JWT is unverifiable).
      #
      # Both deletes run on the Multi's `repo`, so they commit/rollback
      # atomically with the rest of the erasure.
      {family_count, _} =
        repo.delete_all(from f in AuthTokenFamily, where: f.user_id == ^user_id)

      {token_count, _} =
        repo.delete_all(
          from t in "guardian_tokens", prefix: "op", where: t.sub == ^to_string(user_id)
        )

      {:ok, family_count + token_count}
    end)
    |> Multi.run(:audit, fn _repo, _ ->
      Audit.log(nil, "user.data_deleted", resource_type: "user", resource_id: user_id)
    end)
    |> Multi.run(:reset_gdpr_guc, fn repo, _ ->
      repo.query!("RESET app.audit_gdpr_erasure")
      {:ok, :reset}
    end)
    |> Repo.transaction()
  end
end
