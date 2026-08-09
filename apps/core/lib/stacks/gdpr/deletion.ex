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

  Uploaded images (`op.uploaded_images`) are erased both ways: the R2 storage
  objects are deleted via `Stacks.GDPR.ImageRetention.delete_storage_objects/1`
  (before the rows go — the rows are the only pointer to the storage keys),
  then the rows themselves, backed by an ON DELETE CASCADE FK to `op.users`
  (Issue #353, migration `20260805100000`). Before #353 the `user_id` column
  carried no FK, so `repo.delete(user)` left the rows and their storage keys
  behind and the schema-guard stayed blind to it.

  Auth session state (`op.auth_token_families`, `op.guardian_tokens`) is erased
  by the DATABASE, not by this module: both now carry an ON DELETE CASCADE
  foreign key to `op.users` (Issue #335 D3, migration `20260730200200`), so
  `repo.delete(user)` takes them — from any path that deletes a user, not just
  this one. `:revoke_sessions` no longer deletes anything; it asserts the
  cascade fired and fails the erasure if it did not.
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
  alias Stacks.Books.UploadedImage
  alias Stacks.Events.EventLog
  alias Stacks.Feeds.FeedCacheEntry
  alias Stacks.GDPR.ImageRetention
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  @doc """
  Previews what `delete_user_data/2` would erase for a user WITHOUT mutating
  anything — the read-only counterpart used by the operator dry-run
  (`Stacks.Release.gdpr_erase_user/1`).

  Returns `{:ok, counts}` with a per-target row count (using the exact same
  scopes the erasure uses, so the preview cannot drift from the real thing), or
  `{:error, :user_not_found}` if no user has that id.
  """
  @spec preview_user_data(binary()) :: {:ok, map()} | {:error, :user_not_found}
  def preview_user_data(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      _user ->
        bookshelf_ids =
          Repo.all(from bs in Bookshelf, where: bs.user_id == ^user_id, select: bs.id)

        {:ok,
         %{
           bookshelves: length(bookshelf_ids),
           placements: count(from p in Placement, where: p.bookshelf_id in ^bookshelf_ids),
           placement_history:
             count(
               from h in PlacementHistory,
                 where: h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids
             ),
           feed_cache: count(from fc in FeedCacheEntry, where: fc.bookshelf_id in ^bookshelf_ids),
           uploaded_images: count(from i in UploadedImage, where: i.user_id == ^user_id),
           comments_anonymised: count(from c in PostComment, where: c.author_id == ^user_id),
           event_log_rows_scrubbed: count(user_event_log_query(user_id)),
           sessions_revoked: session_row_count(Repo, user_id)
         }}
    end
  end

  defp count(query), do: Repo.aggregate(query, :count)

  # Live auth-session rows keyed to a user, across both session tables. Shared
  # by preview_user_data/1 and the two delete_user_data/2 steps that bracket the
  # user delete, so the preview, the reported count and the post-erasure
  # assertion can never drift from one another.
  #
  # `guardian_tokens` is queried on `sub` (the string the app writes) rather
  # than the generated `user_id` column the FK hangs off: the two are equal by
  # construction, and reading `sub` keeps this count honest even for a row whose
  # `sub` is not a UUID — such a row names no user and must therefore never be
  # counted as one of theirs.
  defp session_row_count(repo, user_id) do
    families = repo.aggregate(from(f in AuthTokenFamily, where: f.user_id == ^user_id), :count)

    tokens =
      repo.aggregate(
        from(t in "guardian_tokens", prefix: "op", where: t.sub == ^to_string(user_id)),
        :count,
        :jti
      )

    families + tokens
  end

  # The set of op.event_log rows the erasure scrubs — the user's own aggregate
  # plus events under other aggregates whose payload references the user. Shared
  # by the :scrub_event_log step and preview_user_data/1 so the two never drift.
  defp user_event_log_query(user_id) do
    uid = to_string(user_id)

    from(e in EventLog,
      where:
        (e.aggregate_type == "user" and e.aggregate_id == ^user_id) or
          fragment("? ->> 'user_id' = ?", e.payload, ^uid) or
          fragment("? ->> 'author_id' = ?", e.payload, ^uid) or
          fragment("? ->> 'seller_id' = ?", e.payload, ^uid)
    )
  end

  @doc """
  Deletes all operational data for a user.

  `opts` may carry `:reason` (operator justification — recorded, encrypted, in
  the `user.data_deleted` audit row's metadata; do NOT put the data subject's
  personal data in it) and `:actor` (who initiated the erasure).

  Returns `{:ok, map()}` on success.
  """
  @spec delete_user_data(binary(), keyword()) :: {:ok, map()} | {:error, atom(), term(), map()}
  def delete_user_data(user_id, opts \\ []) do
    audit_metadata = opts |> Keyword.take([:reason, :actor]) |> Map.new()

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
    |> Multi.run(:delete_feed_cache, fn repo, %{bookshelf_ids: bookshelf_ids} ->
      # GDPR erasure: op.feed_cache holds derived Atom XML for the user's
      # platform-visible bookshelves (the XML embeds user-authored book titles
      # in <title>/<summary>). Its only user path is bookshelf_id →
      # op.bookshelves, which the op.users schema-guard never inspects — so this
      # explicit step is the authoritative erasure guarantee. The FK's ON DELETE
      # CASCADE (from :delete_bookshelves below) is belt-and-suspenders; ordering
      # this BEFORE :delete_bookshelves makes the delete independent of cascade
      # timing. Scoped strictly to the erased user's bookshelves.
      {count, _} =
        repo.delete_all(from fc in FeedCacheEntry, where: fc.bookshelf_id in ^bookshelf_ids)

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
    |> Multi.run(:uploaded_image_rows, fn repo, _ ->
      # GDPR erasure: op.uploaded_images carries the user's user_id AND the R2
      # storage key to their uploaded image bytes. Collect id + storage_path
      # for the user's rows NOW, while the rows still exist — they are the only
      # pointer to the storage keys, so once the FK cascade (added in
      # 20260805100000) removes them the objects would leak unreachable. Scoped
      # strictly to the erased user's rows.
      rows =
        repo.all(
          from i in UploadedImage,
            where: i.user_id == ^user_id,
            select: %{id: i.id, storage_path: i.storage_path}
        )

      {:ok, rows}
    end)
    |> Multi.run(:delete_image_objects, fn _repo, %{uploaded_image_rows: rows} ->
      # Delete the R2 objects BEFORE the rows go. Reuses ImageRetention's
      # storage-deletion path (the same code the 30-day sweep uses) rather than
      # a second copy; a storage-layer failure is logged there and never blocks
      # the erasure. Must run before :delete_uploaded_images / :delete_user.
      ImageRetention.delete_storage_objects(rows)
      {:ok, length(rows)}
    end)
    |> Multi.run(:delete_uploaded_images, fn repo, %{uploaded_image_rows: rows} ->
      # Belt to the FK cascade's braces: the ON DELETE CASCADE FK would take
      # these rows when :delete_user runs, but deleting them explicitly here
      # (after their objects are gone) makes the erasure independent of cascade
      # timing and keeps the guarantee even if the FK is ever weakened —
      # mirroring :delete_feed_cache above. Scoped to the collected ids.
      ids = Enum.map(rows, & &1.id)
      {count, _} = repo.delete_all(from i in UploadedImage, where: i.id in ^ids)
      {:ok, count}
    end)
    |> Multi.run(:sessions_to_revoke, fn repo, _ ->
      # Counted BEFORE the user row goes, because the FKs added in
      # `20260730200200` take these rows with it. The number is what the
      # operator break-glass summary reports (`Stacks.Release.do_erase/2`).
      {:ok, session_row_count(repo, user_id)}
    end)
    # US-14.1.3: settle invitations that NAME this user, before the row goes.
    # One ordered step, deliberately not two: the scrub nulls `redeemed_by_id`,
    # which is the only thing identifying WHICH invitation to restore — split
    # or reordered, the restore silently matches nothing on every reap forever.
    #
    # Restore is CONDITIONAL on the explicit `:restore_invite` opt (default
    # false). Only the two abandoned-signup reap paths pass true — an invitee
    # who never confirmed never became a participant, so their key is unspent.
    # A user-requested erasure must NOT resurrect the code: it was legitimately
    # consumed, and consumption is not undone by the consumer leaving. Never
    # inferred from `:actor` — that is a free-text audit label, and branching
    # security behaviour on a log string breaks when someone rewords it.
    #
    # The scrub itself is unconditional: `note` is the owner's free text about
    # the invitee and `invited_email` is the invitee's address — author-nulling
    # alone would be a breach. The row survives (the beta's issue/revoke
    # history is legitimate record-keeping); every field naming a person goes.
    |> Multi.run(:settle_invites_naming_user, fn repo, _ ->
      settle_invites(repo, user_id, Keyword.get(opts, :restore_invite, false))
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
      {count, _} =
        repo.update_all(user_event_log_query(user_id), set: [payload: %{}, metadata: %{}])

      {:ok, count}
    end)
    |> Multi.run(:revoke_sessions, fn repo, %{sessions_to_revoke: expected} ->
      # Both session tables now carry an ON DELETE CASCADE foreign key to
      # op.users — `auth_token_families.user_id` directly, `guardian_tokens`
      # via the generated `user_id` column derived from `sub` (Issue #335 D3,
      # migration `20260730200200`). `:delete_user` above therefore already
      # removed every row this step used to `delete_all` by hand, from ANY
      # path that deletes a user, not just this one.
      #
      # What remains is the assertion. A cascade that silently stops firing —
      # a constraint dropped in a later migration, a table recreated without
      # it — would leave a hard-deleted user's access token passing
      # verify_claims for up to its 8h TTL, which is exactly the failure the
      # hand-rolled delete existed to prevent. So we recount and fail the
      # whole erasure transaction if anything survived, rather than reporting
      # success over a leak. The `op.users` schema-guard test in
      # `deletion_test.exs` keeps both FKs CASCADE at build time; this is the
      # runtime half of the same guarantee.
      case session_row_count(repo, user_id) do
        0 -> {:ok, expected}
        survivors -> {:error, {:sessions_survived_erasure, survivors}}
      end
    end)
    |> Multi.run(:audit, fn _repo, _ ->
      Audit.log(nil, "user.data_deleted",
        resource_type: "user",
        resource_id: user_id,
        metadata: audit_metadata
      )
    end)
    |> Multi.run(:reset_gdpr_guc, fn repo, _ ->
      repo.query!("RESET app.audit_gdpr_erasure")
      {:ok, :reset}
    end)
    |> Repo.transaction()
  end

  # US-14.1.3 — see the :settle_invites_naming_user step's comment above.
  # Restore (conditional) BEFORE scrub (unconditional): the scrub nulls
  # `redeemed_by_id`, the only pointer identifying which invitation to restore.
  defp settle_invites(repo, user_id, restore?) do
    user_email =
      case repo.get(User, user_id) do
        nil -> nil
        user -> user.email
      end

    if restore? do
      repo.update_all(
        from(i in Stacks.Accounts.InviteCode,
          where: i.redeemed_by_id == ^user_id and i.use_count > 0
        ),
        inc: [use_count: -1],
        set: [redeemed_at: nil]
      )
    end

    {:ok, %{scrubbed: scrub_invites(repo, user_id, user_email), restored: restore?}}
  end

  # The unconditional half of the settle: every field naming a person goes,
  # whichever restore branch ran. The row itself survives as beta history.
  defp scrub_invites(repo, user_id, user_email) do
    {scrubbed, _} =
      repo.update_all(
        from(i in Stacks.Accounts.InviteCode,
          where:
            i.redeemed_by_id == ^user_id or
              (not is_nil(i.invited_email) and
                 fragment("lower(?)", i.invited_email) == ^String.downcase(user_email || "")),
          where: not is_nil(i.note) or not is_nil(i.invited_email) or not is_nil(i.redeemed_by_id)
        ),
        set: [note: nil, invited_email: nil, redeemed_by_id: nil]
      )

    scrubbed
  end
end
