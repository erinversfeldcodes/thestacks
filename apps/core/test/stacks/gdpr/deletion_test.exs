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
  alias Stacks.Accounts.InviteCode
  alias Stacks.Accounts.Invites
  alias Stacks.Admin.SessionContext
  alias Stacks.AdminSession
  alias Stacks.Audit
  alias Stacks.Blog.PostComment
  alias Stacks.Books.UploadedImage
  alias Stacks.Events.EventLog
  alias Stacks.Feeds.FeedCacheEntry
  alias Stacks.GDPR.Deletion
  alias Stacks.GDPR.DeletionTest.RecordingStorage
  alias Stacks.GDPR.DeletionTest.UnreachableStorage
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

    test "scrubs metadata and ip from the erased user's audit rows but preserves the rows" do
      user = insert(:user)
      other = insert(:user)

      Audit.log(user.id, "placement.created",
        resource_type: "placement",
        ip: "197.87.142.19",
        metadata: %{book_id: Ecto.UUID.generate(), bookshelf: "library"}
      )

      Audit.log(other.id, "placement.created",
        resource_type: "placement",
        ip: "10.0.0.1",
        metadata: %{book_id: Ecto.UUID.generate(), bookshelf: "wishlist"}
      )

      before_other =
        Repo.one(
          from(a in "audit_log",
            where: a.user_id == type(^other.id, :binary_id),
            select: %{metadata: a.metadata, ip_address: a.ip_address}
          ),
          prefix: "audit"
        )

      assert {:ok, result} = Deletion.delete_user_data(user.id)
      assert Map.has_key?(result, :scrub_audit_log)

      rows =
        Repo.all(
          from(a in "audit_log",
            where: a.user_id == type(^user.id, :binary_id),
            select: %{
              action: a.action,
              resource_type: a.resource_type,
              occurred_at: a.occurred_at,
              metadata: a.metadata,
              ip_address: a.ip_address
            }
          ),
          prefix: "audit"
        )

      # The trail survives — this is the half the retention decision keeps.
      assert length(rows) == 1
      assert Enum.all?(rows, &(&1.action == "placement.created"))
      assert Enum.all?(rows, &(&1.resource_type == "placement"))
      assert Enum.all?(rows, &(&1.occurred_at != nil))

      # The detail does not. A retained IP digest is unkeyed, so leaving it would
      # leave the erased reader locatable through a column that only looks hashed.
      assert Enum.all?(rows, &(&1.metadata == nil))
      assert Enum.all?(rows, &(&1.ip_address == nil))

      # Another reader's rows are untouched — the scrub is scoped, not a sweep.
      after_other =
        Repo.one(
          from(a in "audit_log",
            where: a.user_id == type(^other.id, :binary_id),
            select: %{metadata: a.metadata, ip_address: a.ip_address}
          ),
          prefix: "audit"
        )

      assert after_other == before_other
      assert after_other.metadata != nil
      assert after_other.ip_address != nil
    end

    test "the erasure's own audit row keeps its operator reason through the scrub" do
      user = insert(:user)

      Audit.log(user.id, "placement.created",
        resource_type: "placement",
        metadata: %{bookshelf: "library"}
      )

      assert {:ok, _result} =
               Deletion.delete_user_data(user.id,
                 reason: "verified DSAR ticket",
                 actor: "gh-actions"
               )

      # The scrub is scoped by user_id and this row carries a nil one, so the
      # record of WHO erased and WHY outlives the pass that erases — without an
      # exception clause that a later scope change could silently drop.
      metadata_bin =
        Repo.one(
          from(a in "audit_log", where: a.action == "user.data_deleted", select: a.metadata),
          prefix: "audit"
        )

      decrypted = metadata_bin |> Stacks.Vault.decrypt!() |> Jason.decode!()
      assert decrypted["reason"] == "verified DSAR ticket"
      assert decrypted["actor"] == "gh-actions"
    end

    test "the scrubbed rows read back as an empty map, matching a scrubbed event row" do
      user = insert(:user)

      Audit.log(user.id, "placement.created",
        resource_type: "placement",
        metadata: %{bookshelf: "library"}
      )

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # Nulling the column rather than storing a fresh ciphertext of `{}` is only
      # safe because the reader maps null to the same value a scrubbed event_log
      # row shows. If that mapping ever goes, this is the test that says so.
      {rows, _page, _total_pages, _per_page} = Audit.list_for_user(user.id)

      assert rows != [], "expected the retained trail to still be listable after erasure"
      assert Enum.all?(rows, &(&1.metadata == %{}))
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

  describe "delete_user_data/1 invitation erasure" do
    # The schema guard below allows `invite_codes` to nilify its user FK on the
    # written justification that "note/invited_email scrubbed by
    # :settle_invites_naming_user step". Nothing tested that the justification was
    # TRUE — and for an issuer it was not: the scrub matched `redeemed_by_id` and
    # `invited_email` but never `issued_by_id`, so erasing the person who WROTE the
    # note nulled the FK and left the note and a third party's email in the row.
    # These tests exist so the justification has to stay true.
    test "erasing the ISSUER scrubs the note they wrote and the email they invited" do
      issuer = insert(:user)

      {:ok, %{invite: invite}} =
        Invites.issue(issuer, %{
          "note" => "Mara from the book club",
          "invited_email" => "mara@example.test"
        })

      assert {:ok, _} = Deletion.delete_user_data(issuer.id)

      row = Repo.get(InviteCode, invite.id)

      assert row, "the row should survive — beta history is kept deliberately"
      assert is_nil(row.note), "the issuer's own free text must not outlive them"
      assert is_nil(row.invited_email), "the invitee's address must not outlive the issuer"
    end

    test "erasing the INVITEE scrubs the invitation naming them" do
      issuer = insert(:user)
      invitee = insert(:user)

      {:ok, %{invite: invite}} =
        Invites.issue(issuer, %{
          "note" => "a friend of a friend",
          "invited_email" => invitee.email
        })

      assert {:ok, _} = Deletion.delete_user_data(invitee.id)

      row = Repo.get(InviteCode, invite.id)

      assert row
      assert is_nil(row.invited_email)
      assert is_nil(row.note)
    end

    test "erasing the ISSUER leaves a third party's redemption on the record" do
      # The issuer's free text and the address they typed are theirs to lose.
      # WHO REDEEMED is not: that is the redeemer's own record, it is what their
      # data export reads to tell them which invitation let them in
      # (`export.ex` matches on `redeemed_by_id`), and nulling it reopens the
      # first-redemption branch so a later redeemer on a multi-use code
      # overwrites it.
      #
      # The bug this pins: widening the scrub's WHERE to cover the issuer
      # without narrowing its SET, so one `update_all` applied a redeemer-shaped
      # `set` to rows that matched for an issuer-shaped reason.
      issuer = insert(:user)
      redeemer = insert(:user)

      {:ok, %{invite: invite}} =
        Invites.issue(issuer, %{
          "note" => "Mara from the book club",
          "invited_email" => "mara@example.test",
          "max_uses" => 2
        })

      invite
      |> Ecto.Changeset.change(
        redeemed_by_id: redeemer.id,
        redeemed_at: DateTime.utc_now(),
        use_count: 1
      )
      |> Repo.update!()

      assert {:ok, _} = Deletion.delete_user_data(issuer.id)

      row = Repo.get(InviteCode, invite.id)

      assert is_nil(row.note), "the issuer's own free text must not outlive them"
      assert is_nil(row.invited_email), "the third party's address goes with the issuer"

      assert row.redeemed_by_id == redeemer.id,
             "the redeemer's own record must survive someone else's erasure — their data " <>
               "export reads this column to tell them which invitation admitted them"

      refute is_nil(row.redeemed_at),
             "a redemption with a redeemer but no timestamp is an incoherent row"
    end

    test "an unrelated user's erasure leaves the invitation alone" do
      issuer = insert(:user)
      bystander = insert(:user)

      {:ok, %{invite: invite}} =
        Invites.issue(issuer, %{
          "note" => "Mara from the book club",
          "invited_email" => "mara@example.test"
        })

      assert {:ok, _} = Deletion.delete_user_data(bystander.id)

      row = Repo.get(InviteCode, invite.id)

      assert row.note == "Mara from the book club", "the scrub must stay scoped, not sweep"
      assert row.invited_email == "mara@example.test"
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

    test "deletes any outstanding data-export object for the user" do
      user = insert(:user)
      key = "exports/#{user.id}/#{DateTime.to_unix(DateTime.utc_now())}-abc.json"
      RecordingStorage.seed_listing("exports/#{user.id}/", [key])

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      assert_received {:storage_delete, ^key}
    end

    test "erasure still completes when the export copy cannot be reached" do
      user = insert(:user)
      Application.put_env(:core, :storage, Stacks.GDPR.DeletionTest.UnreachableStorage)

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      refute Repo.get(Stacks.Accounts.User, user.id)
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
          "would cascade it away; the row keeps a now-dangling id and the shape of the request " <>
          "(action, resource_type, occurred_at) so the platform can still say who did what and " <>
          "when, while erasure scrubs the two fields that carry the person — metadata and the " <>
          "ip digest — through the GUC, which is the only path permitted to mutate this table"
    }

    # Every JSONB/JSON column in a schema this application owns, with what it
    # may hold and how erasure reaches it.
    #
    # ⚠️ THIS LIST EXISTS BECAUSE THE FK GRAPH CANNOT SEE INSIDE A BLOB.
    # `public.oban_jobs.args` held live auth tokens and third-party names for
    # months — `inviter_name`, `buyer_name`, `seller_name`, where the job's own
    # `user_id` is the RECIPIENT and the name belongs to someone else — and both
    # tests above were green throughout, twice over: the queries were scoped to
    # `op`/`audit`, and a reference inside JSONB carries no foreign key for them
    # to inspect even when it is in scope.
    #
    # That second point defeats the obvious fix as well: a scrub keyed on
    # `args->>'user_id'` would not have reached `inviter_name`, because the
    # subject of the data is not the subject of the row.
    #
    # So the mechanism here is declaration, not detection. A new JSONB column
    # fails this test until someone writes down what it can hold — which is the
    # moment to notice that it holds a name.
    @jsonb_column_declarations %{
      "cache.isbn_resolver_cache.metadata" =>
        "external bibliographic data from Open Library / Google Books, keyed by ISBN. No " <>
          "platform user appears in it; the rows are a TTL'd cache of third-party facts about " <>
          "books.",
      "cache.title_search_cache.metadata" =>
        "as above, keyed by search title rather than ISBN. The QUERY STRING is the reader's " <>
          "input, but it is the cache key rather than a column here, and the table is TTL'd.",
      "op.discovered_sources.config_generated" =>
        "generated scraper configuration for a bookshop site — selectors and URLs. The subject " <>
          "is a business, not a person.",
      "op.event_log.payload" =>
        "UUID-only by contract (CLAUDE.md, technical-architecture §21): no names, emails or " <>
          "free text. Erasure scrubs the user's rows to `{}` via the `:scrub_event_log` step, " <>
          "which matches both the user-aggregate rows and cross-aggregate rows by payload " <>
          "`user_id`/`author_id`/`seller_id`. Rows are never deleted — the log is immutable.",
      "op.event_log.metadata" =>
        "emitter-side context (source, correlation ids). Same UUID-only contract and the same " <>
          "scrub step as `payload`.",
      "op.guardian_tokens.claims" =>
        "JWT claims, whose `sub` is the user's own id. Reached TWICE on erasure: the table " <>
          "carries a CASCADE FK on `user_id`, and `Deletion` additionally deletes by `sub` " <>
          "(deletion.ex:112). Belt and braces because guardian_db owns the schema and could " <>
          "stop populating `user_id` without this application noticing.",
      "op.users.onboarding_steps" =>
        "booleans about the user's own onboarding progress. Lives on the user row, so it goes " <>
          "with `repo.delete(user)`.",
      "public.oban_jobs.args" =>
        "job arguments. ⚠️ THE HISTORICAL OFFENDER, now closed: five enqueue sites carried live " <>
          "auth tokens and three carried third-party names; every one of them resolves from ids " <>
          "at DELIVERY instead. Erasure does not reach this table and is not expected to — the " <>
          "invariant is that args hold ids and never the person. A job that outlives its " <>
          "subject resolves nothing and no-ops.",
      "public.oban_jobs.meta" =>
        "Oban's own bookkeeping (recorded uniqueness key, cron hints). Library-owned; this " <>
          "application never writes it."
    }

    # The schemas whose JSONB columns the declaration test governs. `staging`,
    # `intermediate` and `marts` are deliberately absent: they are dbt output,
    # rebuilt in full from the operational tables on every refresh, so they hold
    # no copy erasure needs to reach. Verified 2026-10-16 on a deployed database
    # — 48 of 50 relations are VIEWS, and the only two materialised ones carry
    # book-level aggregates with no identifier in them.
    @jsonb_governed_schemas ~w(op audit cache public)

    # ⚠️ The scope of this guard, and what it cannot see.
    #
    # It asserts FK BEHAVIOUR and nothing else. Where erasure removes rows with
    # an explicit `delete_all` scoped by `user_id` — `op.feedback_entries` is
    # the clearest case — that step works whatever the FK does, so deleting the
    # step leaves this guard GREEN. Each such step is guarded only by its own
    # per-table test asserting on the CONTENT (for feedback, "erasure DELETES
    # the body" in `feedback_test.exs`), which in turn stays green if the FK is
    # relaxed. Established by probe: flipping that FK to SET NULL in the test
    # database fired this guard and left the body test passing.
    #
    # So the two defences do not back each other up. Changing either mechanism
    # means reading the other one's test, because the green you get for free is
    # from the half you did not touch.
    #
    # The second limit is the allowlist above: each entry's justification is a
    # SENTENCE, and nothing here checks whether it is true. One of them was
    # false for months — the invite entry claimed the scrub step covered
    # `note`/`invited_email`, and the scrub never matched the ISSUER, so an
    # erased issuer's own free text stayed in the row.
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

    # The blind spot the two tests above share, closed by declaration.
    #
    # Both reach rows through the FK graph, and a reference held inside a JSONB
    # blob has no foreign key to inspect. `public.oban_jobs.args` carried live
    # auth tokens and three third-party names while both stayed green.
    test "every JSONB column in an owned schema declares what it may hold" do
      {:ok, %{rows: rows}} =
        Repo.query(
          """
          SELECT n.nspname, c.relname, a.attname
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
           WHERE n.nspname = ANY($1)
             AND c.relkind = 'r'
             AND a.attnum > 0
             AND NOT a.attisdropped
             AND t.typname IN ('jsonb', 'json')
           ORDER BY 1, 2, 3
          """,
          [@jsonb_governed_schemas]
        )

      found = for [schema, table, col] <- rows, do: "#{schema}.#{table}.#{col}"

      undeclared = Enum.reject(found, &Map.has_key?(@jsonb_column_declarations, &1))

      assert undeclared == [],
             "JSONB column(s) with no declaration of what they may hold: " <>
               "#{inspect(undeclared)}. The FK-based guards above cannot see inside a blob — " <>
               "`oban_jobs.args` held live auth tokens and three third-party names while both " <>
               "were green — so a new JSONB column has to say for itself. Add it to " <>
               "@jsonb_column_declarations stating what it may contain and how erasure reaches " <>
               "it; if the answer turns out to be 'a person's name', that is the finding."

      # Anti-vacuity, and specifically against the shape that made this
      # necessary: a declaration list is satisfied by an empty query, and the
      # query was wrong-by-scope for months. Naming the historical offender
      # means a scope that stops covering `public` fails here rather than
      # passing quietly.
      assert "public.oban_jobs.args" in found,
             "the sweep did not find public.oban_jobs.args — it is not reading the schemas it " <>
               "names, which is exactly how the original guard missed this column"

      stale = Enum.reject(Map.keys(@jsonb_column_declarations), &(&1 in found))

      assert stale == [],
             "declared JSONB column(s) that no longer exist: #{inspect(stale)}. A declaration " <>
               "for a dropped column is a sentence nobody will re-read; remove it."
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
  def list(prefix), do: {:ok, Process.get({__MODULE__, prefix}, [])}

  @impl true
  def delete(key) do
    send(self(), {:storage_delete, key})
    :ok
  end

  @doc "Make `list/1` answer `keys` for `prefix`."
  def seed_listing(prefix, keys), do: Process.put({__MODULE__, prefix}, keys)
end

defmodule Stacks.GDPR.DeletionTest.UnreachableStorage do
  @moduledoc """
      Test-local storage backend that is simply down. Erasure of the user's rows
      must not be held hostage to it — the deadline encoded in each export key
      is what guarantees the unreachable copy still goes.
  """

  @behaviour Stacks.Storage.StorageBehaviour

  @impl true
  def put(_key, _data, _opts \\ []), do: {:error, :circuit_open}

  @impl true
  def presigned_url(_key, _ttl_seconds \\ 900), do: {:error, :circuit_open}

  @impl true
  def presigned_put_url(_key, _ttl_seconds \\ 900, _opts \\ []), do: {:error, :circuit_open}

  @impl true
  def head(_key), do: {:error, :circuit_open}

  @impl true
  def list(_prefix), do: {:error, :circuit_open}

  @impl true
  def delete(_key), do: {:error, :circuit_open}
end
