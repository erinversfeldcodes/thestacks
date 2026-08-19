defmodule Stacks.GDPR.DeletionTest do
  @moduledoc """
      Erasure must be able to modify the append-only audit log. A `Multi.run`
      issues `SET LOCAL app.audit_gdpr_erasure = 'true'` before audit cleanup;
      these tests assert the GUC works inside the transaction (an audit-row
      UPDATE succeeds under the trigger) and is LOCAL (the same UPDATE outside
      the transaction is still refused), and that erasure reaches every row a
      user owns — by cascade where there is an FK, by an explicit step where
      the content is theirs to have deleted.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.AuthTokenFamily
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.AdminSession
  alias Stacks.Audit
  alias Stacks.Blog.PostComment
  alias Stacks.Books.UploadedImage
  alias Stacks.Events.EventLog
  alias Stacks.Feeds.FeedCacheEntry
  alias Stacks.GDPR.Deletion
  alias Stacks.MFA
  alias Stacks.MFA.UserMFA

  defp seed_legacy_event(attrs) do
    Repo.insert!(%EventLog{
      event_type: attrs.event_type,
      aggregate_type: attrs.aggregate_type,
      aggregate_id: attrs.aggregate_id,
      schema_version: Map.get(attrs, :schema_version, 1),
      payload: Map.get(attrs, :payload, %{}),
      metadata: Map.get(attrs, :metadata, %{}),
      occurred_at: DateTime.utc_now()
    })
  end

  describe "delete_user_data/1 GUC integration" do
    test "delete_user_data records the GDPR erasure GUC value in the multi result" do
      user = insert(:user)
      {:ok, _entry} = Audit.log(user.id, "user.login", resource_type: "user")

      assert {:ok, result_map} = Deletion.delete_user_data(user.id)

      keys = Map.keys(result_map) |> Enum.map(&to_string/1)

      guc_key =
        Enum.find(keys, fn k ->
          String.contains?(k, "gdpr") or String.contains?(k, "guc") or
            String.contains?(k, "audit_erasure")
        end)

      assert guc_key,
             "expected delete_user_data/1's :ok result map to include a GDPR erasure GUC step (key containing 'gdpr', 'guc', or 'audit_erasure'), got keys: #{inspect(keys)}"
    end

    test "GUC is scoped to the deletion transaction (does not leak)" do
      user = insert(:user)
      {:ok, entry} = Audit.log(user.id, "user.login", resource_type: "user")

      other_user = insert(:user)
      {:ok, other_entry} = Audit.log(other_user.id, "other.login", resource_type: "user")

      _ = entry
      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 "UPDATE audit.audit_log SET action = $1 WHERE id = $2",
                 ["leak.test", Ecto.UUID.dump!(other_entry.id)]
               )
    end
  end

  describe "delete_user_data/1 audit + event_log invariants" do
    test "writes a user.data_deleted audit row with nil user_id and the deleted user's id as resource_id" do
      user = insert(:user)

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      row =
        Repo.one(
          from(a in "audit_log",
            where: a.action == "user.data_deleted",
            select: %{
              user_id: a.user_id,
              resource_type: a.resource_type,
              resource_id: a.resource_id
            }
          ),
          prefix: "audit"
        )

      assert row, "expected a user.data_deleted audit row after erasure"
      assert row.user_id == nil
      assert row.resource_type == "user"
      assert row.resource_id == Ecto.UUID.dump!(user.id)
    end

    test "records the operator:reason (encrypted) in the erasure audit row" do
      user = insert(:user)

      assert {:ok, _result} =
               Deletion.delete_user_data(user.id,
                 reason: "verified DSAR ticket",
                 actor: "gh-actions"
               )

      metadata_bin =
        Repo.one(
          from(a in "audit_log", where: a.action == "user.data_deleted", select: a.metadata),
          prefix: "audit"
        )

      decrypted = metadata_bin |> Stacks.Vault.decrypt!() |> Jason.decode!()
      assert decrypted["reason"] == "verified DSAR ticket"
      assert decrypted["actor"] == "gh-actions"
    end

    test "scrubs PII from the erased user's own event_log rows but preserves the rows" do
      user = insert(:user)
      other_id = Ecto.UUID.generate()

      seed_legacy_event(%{
        event_type: "user.profile_updated",
        aggregate_type: "user",
        aggregate_id: user.id,
        payload: %{display_name: "Ada Lovelace"},
        metadata: %{ip: "10.0.0.1"}
      })

      seed_legacy_event(%{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: other_id,
        payload: %{isbn: "9780262510875", title: "SICP"}
      })

      before_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_id))

      assert {:ok, result} = Deletion.delete_user_data(user.id)

      assert Map.has_key?(result, :scrub_event_log)

      user_rows =
        Repo.all(
          from(e in EventLog, where: e.aggregate_type == "user" and e.aggregate_id == ^user.id)
        )

      assert length(user_rows) == 1
      assert Enum.all?(user_rows, &(&1.payload == %{}))
      assert Enum.all?(user_rows, &(&1.metadata == %{}))

      after_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_id))
      assert after_other == before_other
    end

    test "scrubs the user's free-text PII from events under NON-user aggregates" do
      user = insert(:user)
      other_user = insert(:user)
      post_id = Ecto.UUID.generate()
      other_post_id = Ecto.UUID.generate()

      seed_legacy_event(%{
        event_type: "blog.post_created",
        aggregate_type: "post",
        aggregate_id: post_id,
        payload: %{
          user_id: user.id,
          title: "My deeply personal post title",
          visibility: "public"
        }
      })

      seed_legacy_event(%{
        event_type: "blog.post_created",
        aggregate_type: "post",
        aggregate_id: other_post_id,
        payload: %{
          user_id: other_user.id,
          title: "Someone else's post",
          visibility: "public"
        }
      })

      before_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_post_id))

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      erased_row = Repo.one(from(e in EventLog, where: e.aggregate_id == ^post_id))
      assert erased_row.payload == %{}
      assert erased_row.metadata == %{}

      after_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_post_id))
      assert after_other == before_other
      assert after_other.payload["title"] == "Someone else's post"
    end
  end

  describe "delete_user_data/1 session revocation" do
    defp open_session(user) do
      fid = Ecto.UUID.generate()
      {:ok, token, claims} = Guardian.encode_and_sign(user, %{"family_id" => fid})

      {:ok, _family} =
        Accounts.rotate_token_family(%{
          family_id: fid,
          user_id: user.id,
          current_jti: claims["jti"],
          session_started_at: DateTime.from_unix!(claims["sst"])
        })

      %{fid: fid, token: token}
    end

    defp guardian_token_count(user_id) do
      Repo.aggregate(
        from(t in "guardian_tokens", prefix: "op", where: t.sub == ^to_string(user_id)),
        :count,
        :jti
      )
    end

    defp family_count(user_id) do
      Repo.aggregate(from(f in AuthTokenFamily, where: f.user_id == ^user_id), :count, :family_id)
    end

    test "erasing a user deletes their auth_token_families and guardian_tokens rows" do
      user = insert(:user)
      _session = open_session(user)

      assert guardian_token_count(user.id) == 1
      assert family_count(user.id) == 1

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      assert guardian_token_count(user.id) == 0
      assert family_count(user.id) == 0
    end

    test "the erasure reports how many sessions it killed, and fails if any survive" do
      user = insert(:user)
      _session = open_session(user)

      assert {:ok, result} = Deletion.delete_user_data(user.id)

      assert result.sessions_to_revoke == 2,
             "one auth_token_families row + one guardian_tokens row"

      assert result.revoke_sessions == 2, "the reported count must survive the cascade rewrite"
      assert guardian_token_count(user.id) == 0
      assert family_count(user.id) == 0
    end

    test "the erased user's live token no longer verifies" do
      user = insert(:user)
      %{token: token} = open_session(user)

      assert {:ok, _claims} = Guardian.decode_and_verify(token)

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      assert {:error, _reason} = Guardian.decode_and_verify(token)
    end
  end

  describe "delete_user_data/1 cascade deletion" do
    test "deletes user_mfa and admin_sessions when user is deleted" do
      user = insert(:user)

      {:ok, %{secret: secret, recovery_codes: codes}} = MFA.begin_enrollment(user)
      valid_code = NimbleTOTP.verification_code(secret)
      {:ok, mfa} = MFA.confirm_enrollment(user, valid_code, secret, codes)

      {:ok, session} = SessionContext.create(user, "127.0.0.1", Core.Application.boot_id())

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      assert is_nil(Repo.get(UserMFA, mfa.id))
      assert is_nil(Repo.get(AdminSession, session.id))
    end
  end

  describe "delete_user_data/1 blog comment erasure" do
    test "tombstones the erased user's post_comment bodies but leaves other users' comments intact" do
      erased_user = insert(:user)
      other_user = insert(:user)

      mine =
        insert(:post_comment, author: erased_user, body: "my deeply personal confession")

      reply =
        insert(:post_comment,
          post: mine.post,
          author: other_user,
          parent_id: mine.id,
          body: "a stranger's reply"
        )

      theirs = insert(:post_comment, author: other_user, body: "unrelated public thoughts")

      assert {:ok, result} = Deletion.delete_user_data(erased_user.id)
      assert Map.has_key?(result, :erase_comments)

      reloaded_mine = Repo.get(PostComment, mine.id)
      assert reloaded_mine, "the comment row must survive (thread structure preserved)"
      refute reloaded_mine.body =~ "confession"
      assert reloaded_mine.body == "[deleted]"
      assert reloaded_mine.author_id == nil

      reloaded_reply = Repo.get(PostComment, reply.id)
      assert reloaded_reply.body == "a stranger's reply"
      assert reloaded_reply.author_id == other_user.id
      assert reloaded_reply.parent_id == mine.id

      reloaded_theirs = Repo.get(PostComment, theirs.id)
      assert reloaded_theirs.body == "unrelated public thoughts"
      assert reloaded_theirs.author_id == other_user.id
    end
  end

  describe "delete_user_data/1 feed cache erasure" do
    test "erasing a user removes their feed_cache rows and preview reports the count" do
      user = insert(:user, profile_visibility: "platform")
      other = insert(:user, profile_visibility: "platform")

      bs1 = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      bs2 = insert(:bookshelf, user: user, name: "antilibrary", visibility: "platform")
      other_bs = insert(:bookshelf, user: other, name: "library", visibility: "platform")

      for bs <- [bs1, bs2, other_bs] do
        Repo.insert!(%FeedCacheEntry{
          bookshelf_id: bs.id,
          atom_xml: "<feed xmlns=\"x\">#{bs.id}</feed>",
          etag: "etag-#{bs.id}"
        })
      end

      assert {:ok, preview} = Deletion.preview_user_data(user.id)
      assert preview.feed_cache == 2

      assert {:ok, result} = Deletion.delete_user_data(user.id)
      assert Map.has_key?(result, :delete_feed_cache)

      assert Repo.aggregate(
               from(fc in FeedCacheEntry, where: fc.bookshelf_id in ^[bs1.id, bs2.id]),
               :count
             ) == 0

      assert Repo.get_by(FeedCacheEntry, bookshelf_id: other_bs.id)
    end
  end

  describe "delete_user_data/1 uploaded image erasure" do
    test "erasing a user removes their uploaded_images rows immediately" do
      user = insert(:user)

      {:ok, image} =
        Repo.insert(%UploadedImage{
          user_id: user.id,
          storage_path: "uploads/probe-#{user.id}",
          status: "pending",
          uploaded_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
        })

      assert Repo.aggregate(from(i in UploadedImage, where: i.user_id == ^user.id), :count) == 1

      assert {:ok, result} = Deletion.delete_user_data(user.id)

      assert Repo.aggregate(from(i in UploadedImage, where: i.user_id == ^user.id), :count) == 0
      refute Repo.get(UploadedImage, image.id)
      assert Map.has_key?(result, :delete_uploaded_images)
    end

    test "does not touch another user's uploaded_images rows" do
      user = insert(:user)
      other = insert(:user)

      Repo.insert!(%UploadedImage{
        user_id: user.id,
        storage_path: "uploads/mine",
        status: "pending",
        uploaded_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      })

      other_image =
        Repo.insert!(%UploadedImage{
          user_id: other.id,
          storage_path: "uploads/theirs",
          status: "pending",
          uploaded_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
        })

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      assert Repo.get(UploadedImage, other_image.id)
    end
  end

  describe "delete_user_data/1 uploaded image storage deletion" do
    setup do
      Application.put_env(:core, :storage, Stacks.GDPR.DeletionTest.RecordingStorage)
      on_exit(fn -> Application.put_env(:core, :storage, Stacks.Storage.Mock) end)
      :ok
    end

    test "deletes the R2 object for each of the user's images" do
      user = insert(:user)

      Repo.insert!(%UploadedImage{
        user_id: user.id,
        storage_path: "uploads/obj-a",
        status: "resolved",
        uploaded_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      })

      Repo.insert!(%UploadedImage{
        user_id: user.id,
        storage_path: "uploads/obj-b",
        status: "pending",
        uploaded_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      })

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      assert_received {:storage_delete, "uploads/obj-a"}
      assert_received {:storage_delete, "uploads/obj-b"}
      refute_received {:storage_delete, _other}
    end
  end

  describe "erasure completeness — schema-level guard" do
    @nilify_user_fk_allowlist %{
      "transactions" => "financial-audit / legal retention; no user free-text",
      "partners" => "business entity (partner record); approver de-linked on erasure",
      "post_comments" => "free-text body erased by :erase_comments step; nilify preserves thread",
      "invite_codes" =>
        "note/invited_email scrubbed by :settle_invites_naming_user step; nilify keeps beta history"
    }

    # A uuid column whose NAME reads like a user reference but which either does
    # not point at a platform user, or points at rows that outlive erasure on
    # purpose. Anything not listed here must carry a real FK — the name pattern
    # is the only thing standing between a new user-scoping column and silent
    # survival, because erasure reaches rows through the FK graph alone.
    @fkless_user_column_allowlist %{
      "op.books.author_id" => "op.authors — the writer of the book, not a platform user",
      "op.bookstore_events.author_id" => "op.authors — an event's featured writer, not a user",
      "audit.audit_log.user_id" =>
        "the audit trail is retained past erasure by design, so it deliberately has no FK that " <>
          "would cascade it away; the row keeps a now-dangling id, a hashed IP and encrypted " <>
          "operator metadata, and the erasure GUC is the only path that may mutate it"
    }

    test "every op.* FK that references op.users cascades, or nullifies only on the allowlist" do
      {:ok, %{rows: rows}} =
        Repo.query("""
        SELECT c.relname, a.attname, con.confdeltype
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class rc ON rc.oid = con.confrelid
        JOIN pg_namespace rn ON rn.oid = rc.relnamespace
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
        WHERE n.nspname = 'op'
          AND con.contype = 'f'
          AND rn.nspname = 'op'
          AND rc.relname = 'users'
        """)

      offenders =
        for [table, col, deltype] <- rows,
            deltype != "c",
            not (deltype == "n" and Map.has_key?(@nilify_user_fk_allowlist, table)),
            do: "#{table}.#{col} (#{deltype})"

      assert offenders == [],
             "op.* FKs referencing op.users that are neither CASCADE nor an allowlisted " <>
               "SET NULL (erasure would orphan/leak PII or break). Offenders: " <>
               "#{inspect(offenders)}. If a nilify is intentional, add the table to " <>
               "@nilify_user_fk_allowlist WITH a justification AND ensure any user free-text " <>
               "on it is erased by a delete_user_data/1 step."
    end

    test "every user-referencing column in op and audit has a foreign key to op.users" do
      {:ok, %{rows: rows}} =
        Repo.query("""
        SELECT n.nspname, c.relname, a.attname
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_type t ON t.oid = a.atttypid
        WHERE n.nspname IN ('op', 'audit')
          AND c.relkind = 'r'
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND t.typname = 'uuid'
          AND (a.attname = 'user_id'
               OR a.attname LIKE '%\\_user\\_id'
               OR a.attname LIKE '%\\_by\\_id'
               OR a.attname LIKE '%\\_to\\_id'
               OR a.attname IN ('author_id', 'actor_id', 'owner_id', 'seller_id',
                                'buyer_id', 'sender_id', 'recipient_id', 'blocker_id',
                                'blocked_id', 'follower_id', 'followed_id',
                                'member_id', 'requester_id', 'reviewer_id'))
          AND NOT EXISTS (
            SELECT 1
            FROM pg_constraint con
            JOIN pg_class rc ON rc.oid = con.confrelid
            JOIN pg_namespace rn ON rn.oid = rc.relnamespace
            WHERE con.contype = 'f'
              AND con.conrelid = c.oid
              AND a.attnum = ANY(con.conkey)
              AND rn.nspname = 'op'
              AND rc.relname = 'users'
          )
        ORDER BY n.nspname, c.relname, a.attname
        """)

      offenders =
        for [schema, table, col] <- rows,
            not Map.has_key?(@fkless_user_column_allowlist, "#{schema}.#{table}.#{col}"),
            do: "#{schema}.#{table}.#{col}"

      assert offenders == [],
             "columns that name a user but carry no foreign key to op.users. Erasure reaches " <>
               "personal data via repo.delete(user) + FK CASCADE; a user-scoping column with " <>
               "no FK is invisible to that path and to the CASCADE audit above, so the user's " <>
               "rows survive erasure silently. Offenders: #{inspect(offenders)}. Add a CASCADE " <>
               "FK to op.users, or — if the column does not name a platform user at all, or " <>
               "the rows are deliberately retained past erasure — add it to " <>
               "@fkless_user_column_allowlist WITH the reason."
    end
  end
end

defmodule Stacks.GDPR.DeletionTest.RecordingStorage do
  @moduledoc """
      Test-local storage backend that records every `delete/1` call by sending
      `{:storage_delete, key}` to the process that ran the deletion. `delete/1`
      runs synchronously inside `delete_user_data/1`'s erasure transaction, so
      `self` is the test process and the message lands in its mailbox.
  """

  @behaviour Stacks.Storage.StorageBehaviour

  @impl true
  def put(key, _data, _opts \\ []), do: {:ok, key}

  @impl true
  def presigned_url(key, _ttl_seconds \\ 900), do: {:ok, key}

  @impl true
  def presigned_put_url(key, _ttl_seconds \\ 900, _opts \\ []), do: {:ok, key}

  @impl true
  def head(_key), do: {:error, :not_found}

  @impl true
  def delete(key) do
    send(self(), {:storage_delete, key})
    :ok
  end
end
