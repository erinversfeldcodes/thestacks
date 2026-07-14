defmodule Stacks.GDPR.Deletion do
  @moduledoc """
  GDPR right-to-erasure. Deletes all operational data for a user.

  All operations run in a single `Ecto.Multi` transaction to ensure atomicity.
  A deletion record is inserted into the audit_log after all data is removed.

  `op.event_log` rows are preserved (the event stream is immutable — events are
  never deleted, including during erasure), but the erased user's own rows are
  scrubbed in place: their `payload` and `metadata` are redacted to `{}` so no
  PII survives. Current `user.*` emitters are UUID-only, so this only bites
  legacy rows written before Issue #121 — but it runs unconditionally as a
  safety net. `op.event_log` has no append-only trigger (unlike
  `audit.audit_log`), so the scrub is a plain UPDATE needing no GUC.
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
  alias Stacks.Blog.PostComment
  alias Stacks.Events.EventLog
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
    |> Multi.run(:erase_comments, fn repo, _ ->
      # GDPR erasure: op.post_comments.body is user-authored free-text PII.
      # The author_id FK is ON DELETE SET NULL, so `repo.delete(user)` below
      # nulls authorship but leaves the comment BODY behind — a right-to-erasure
      # leak (#185). Comments are threaded (parent_id → replies), so deleting
      # the user's comments outright would orphan any replies hanging off them.
      # We therefore ANONYMISE: tombstone the body (strips the PII) and null
      # author_id in-step (keeping the row self-consistent within this txn; the
      # FK would null it anyway on delete_user). Thread structure is preserved.
      # Scoped strictly to the erased user's own comments.
      {count, _} =
        repo.update_all(
          from(c in PostComment, where: c.author_id == ^user_id),
          set: [body: "[deleted]", author_id: nil]
        )

      {:ok, count}
    end)
    |> Multi.run(:delete_user, fn repo, _ ->
      case repo.get(User, user_id) do
        nil -> {:error, :user_not_found}
        user -> repo.delete(user)
      end
    end)
    |> Multi.run(:scrub_event_log, fn repo, _ ->
      # GDPR erasure: redact any PII/free-text the erased user's events wrote
      # into op.event_log payload/metadata. We UPDATE rather than DELETE to
      # preserve event-stream immutability — the event survives, only its PII
      # is emptied. Two classes of row are scrubbed:
      #
      #   1. The user's OWN aggregate (`aggregate_type == "user"`, e.g. legacy
      #      user.profile_updated with display_name; current emitters are
      #      UUID-only but this is a safety net for legacy rows).
      #   2. Events *about* the user emitted under a DIFFERENT aggregate whose
      #      payload references the user — notably `blog.post_created` /
      #      `blog.post_published` (aggregate_type "post") which carry the
      #      user's free-text post `title` alongside `user_id`. We match those
      #      by the payload's user-reference keys (user_id/author_id/seller_id),
      #      closing the cross-aggregate free-text leak (#185). Bare-UUID
      #      references that remain elsewhere are acceptable per the
      #      UUIDs-are-not-PII contract.
      #
      # op.event_log has NO append-only trigger (unlike audit.audit_log), so
      # this plain UPDATE needs no `app.audit_gdpr_erasure` GUC. It runs on the
      # Multi's `repo`, so it commits/rolls back atomically with the erasure.
      uid = to_string(user_id)

      {count, _} =
        repo.update_all(
          from(e in EventLog,
            where:
              (e.aggregate_type == "user" and e.aggregate_id == ^user_id) or
                fragment("? ->> 'user_id' = ?", e.payload, ^uid) or
                fragment("? ->> 'author_id' = ?", e.payload, ^uid) or
                fragment("? ->> 'seller_id' = ?", e.payload, ^uid)
          ),
          set: [payload: %{}, metadata: %{}]
        )

      {:ok, count}
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
