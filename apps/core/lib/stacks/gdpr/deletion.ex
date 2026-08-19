defmodule Stacks.GDPR.Deletion do
  @moduledoc """
      GDPR right-to-erasure: deletes all of a user's operational data in one
      `Ecto.Multi` transaction, then writes an audit record. `op.event_log`
      rows are preserved (immutable stream) but the user's own rows have
      `payload`/`metadata` scrubbed to `{}` in place — current emitters are
      UUID-only, so this is a safety net for pre-121 legacy rows. Uploaded
      images are erased both ways: R2 objects deleted, DB rows cascade.
      A schema-guard test walks every table naming `user_id` and fails when a
      new one is not covered here — free-text must be deleted/anonymised,
      never just author-nulled.

      Outstanding GDPR export objects are erased too. They live only in object
      storage, so no table names them and the schema guard cannot see them;
      `Stacks.GDPR.ExportDelivery` finds them by key prefix instead.
  """

  # Ecto.Multi uses an opaque MapSet internally; dialyzer cannot resolve the
  # opaque subterms after Multi.new() and fires call_without_opaque on every
  # chained call. This is a known false positive.
  @dialyzer :no_opaque

  import Ecto.Query

  require Logger

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.User
  alias Stacks.Audit
  alias Stacks.Blog.PostComment
  alias Stacks.Books.UploadedImage
  alias Stacks.Events.EventLog
  alias Stacks.Feedback.Entry, as: FeedbackEntry
  alias Stacks.Feeds.FeedCacheEntry
  alias Stacks.GDPR.ExportDelivery
  alias Stacks.GDPR.ImageRetention
  alias Stacks.Imports.LibraryImport
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  @doc """
      Previews what `delete_user_data/2` would erase for a user WITHOUT mutating
      anything — the read-only counterpart used by the operator dry-run
      (`Stacks.Release.gdpr_erase_user/1`).

      Returns `{:ok, counts}` with a per-target row count (using the exact same
      scopes the erasure uses, so the preview cannot drift from the real thing), or
      `{:error,:user_not_found}` if no user has that id.
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
           library_imports: count(from li in LibraryImport, where: li.user_id == ^user_id),
           feedback_entries: count(from f in FeedbackEntry, where: f.user_id == ^user_id),
           comments_anonymised: count(from c in PostComment, where: c.author_id == ^user_id),
           event_log_rows_scrubbed: count(user_event_log_query(user_id)),
           sessions_revoked: session_row_count(Repo, user_id)
         }}
    end
  end

  defp count(query), do: Repo.aggregate(query, :count)

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

      Returns `{:ok, map}` on success.
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
    |> Multi.run(:delete_library_imports, fn repo, _ ->
      {count, _} = repo.delete_all(from li in LibraryImport, where: li.user_id == ^user_id)
      {:ok, count}
    end)
    |> Multi.run(:delete_history, fn repo, %{bookshelf_ids: bookshelf_ids} ->
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
      {count, _} =
        repo.delete_all(from fc in FeedCacheEntry, where: fc.bookshelf_id in ^bookshelf_ids)

      {:ok, count}
    end)
    |> Multi.run(:delete_bookshelves, fn repo, _ ->
      {count, _} = repo.delete_all(from bs in Bookshelf, where: bs.user_id == ^user_id)
      {:ok, count}
    end)
    # DELETE, not author-null: the body is the reader's own words, and a row
    # that survives with a null user_id is a message from someone who asked to
    # be forgotten sitting in the owner's queue. Explicit rather than left to
    # the FK cascade so the operator summary can report a count.
    |> Multi.run(:delete_feedback_entries, fn repo, _ ->
      {count, _} = repo.delete_all(from f in FeedbackEntry, where: f.user_id == ^user_id)
      {:ok, count}
    end)
    |> Multi.run(:erase_comments, fn repo, _ ->
      {count, _} =
        repo.update_all(
          from(c in PostComment, where: c.author_id == ^user_id),
          set: [body: "[deleted]", author_id: nil]
        )

      {:ok, count}
    end)
    |> Multi.run(:uploaded_image_rows, fn repo, _ ->
      rows =
        repo.all(
          from i in UploadedImage,
            where: i.user_id == ^user_id,
            select: %{id: i.id, storage_path: i.storage_path}
        )

      {:ok, rows}
    end)
    |> Multi.run(:delete_image_objects, fn _repo, %{uploaded_image_rows: rows} ->
      ImageRetention.delete_storage_objects(rows)
      {:ok, length(rows)}
    end)
    |> Multi.run(:delete_uploaded_images, fn repo, %{uploaded_image_rows: rows} ->
      ids = Enum.map(rows, & &1.id)
      {count, _} = repo.delete_all(from i in UploadedImage, where: i.id in ^ids)
      {:ok, count}
    end)
    |> Multi.run(:delete_export_objects, fn _repo, _ ->
      case ExportDelivery.delete_user_exports(user_id) do
        {:ok, count} ->
          {:ok, count}

        {:error, reason} ->
          # Storage being down must not strand the user's rows in the database.
          # The deadline in each export key means the sweep still collects them.
          Logger.error(
            "Deletion: export objects for #{user_id} survived erasure: #{inspect(reason)}"
          )

          {:ok, 0}
      end
    end)
    |> Multi.run(:sessions_to_revoke, fn repo, _ ->
      {:ok, session_row_count(repo, user_id)}
    end)
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
      {count, _} =
        repo.update_all(user_event_log_query(user_id), set: [payload: %{}, metadata: %{}])

      {:ok, count}
    end)
    |> Multi.run(:revoke_sessions, fn repo, %{sessions_to_revoke: expected} ->
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
