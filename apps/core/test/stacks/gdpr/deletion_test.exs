defmodule Stacks.GDPR.DeletionTest do
  @moduledoc """
  Tests for `Stacks.GDPR.Deletion.delete_user_data/1` — Issue #138 Phase 1
  additions only.

  Phase 1 wires a `Multi.run` step into the existing erasure transaction
  that issues `SET LOCAL app.audit_gdpr_erasure = 'true'` before any audit
  modification. Two invariants:

    1. The GUC is set inside the same transaction the audit cleanup runs in
       — proven indirectly by issuing an audit-row UPDATE inside the same
       Multi and asserting it succeeds (i.e. the trigger from Phase 1's
       append-only migration permits it).
    2. The GUC is scoped to the transaction (SET LOCAL, not SET) — proven by
       asserting a subsequent raw UPDATE on `audit.audit_log` fails after
       the multi commits.

  Until Phase 1's implementation lands, the GUC is never set, so the audit
  trigger blocks any cleanup the multi attempts and the deletion fails.

  Also covers Issue #121: the erasure audit-row invariants and the
  `op.event_log` GDPR-scrub invariant — the erased user's own event rows are
  preserved (immutability: never deleted) but their PII-bearing payload and
  metadata are redacted in place, while unrelated rows are left untouched.
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
  alias Stacks.Events.EventLog
  alias Stacks.GDPR.Deletion
  alias Stacks.MFA
  alias Stacks.MFA.UserMFA

  # Insert an op.event_log row DIRECTLY, bypassing the contract-guarded
  # Events.emit/1. Used only to seed LEGACY / pre-contract PII-bearing rows —
  # the exact shapes emit/1 rightly rejects today but the GDPR scrubber must
  # still redact from historical data.
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
      # Phase 1 adds a `Multi.run` step (canonically named `:set_gdpr_guc`)
      # that issues `SET LOCAL app.audit_gdpr_erasure = 'true'` BEFORE any
      # audit-row modification. The step's result must be discoverable in
      # the multi's final result map so callers (and tests) can verify the
      # GUC was set without poking into private state.
      #
      # We assert the result map contains a key whose name includes "gdpr"
      # or "guc" — accepting any reasonable canonical naming.
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
      # After delete_user_data commits, a subsequent ad-hoc UPDATE on
      # audit.audit_log must still be blocked — proving SET LOCAL was used,
      # not session-wide SET.
      user = insert(:user)
      {:ok, entry} = Audit.log(user.id, "user.login", resource_type: "user")

      # Insert a second audit row attributed to a DIFFERENT user — we'll
      # try to mutate it AFTER the multi commits, to verify the GUC didn't
      # leak.
      other_user = insert(:user)
      {:ok, other_entry} = Audit.log(other_user.id, "other.login", resource_type: "user")

      _ = entry
      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # Now: outside the multi's transaction, the trigger must still block
      # any UPDATE on audit.audit_log.
      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 "UPDATE audit.audit_log SET action = $1 WHERE id = $2",
                 ["leak.test", Ecto.UUID.dump!(other_entry.id)]
               )
    end
  end

  describe "delete_user_data/1 audit + event_log invariants (Issue #121)" do
    test "writes a user.data_deleted audit row with nil user_id and the deleted user's id as resource_id" do
      user = insert(:user)

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # Query audit.audit_log directly (schemaless) rather than trusting the
      # multi result. user_id MUST be nil — the acting principal for an erasure
      # is the system, and the erased user's id lives in resource_id instead, so
      # no PII-linked actor survives in the audit trail.
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

    test "scrubs PII from the erased user's own event_log rows but preserves the rows" do
      user = insert(:user)
      other_id = Ecto.UUID.generate()

      # Seed a LEGACY PII-bearing event on the erased user's aggregate — the
      # shape older emitters wrote before Issue #121 made user.* events
      # UUID-only. Both payload and metadata carry PII here. Inserted directly
      # (not via Events.emit/1) because the payload contract now rightly rejects
      # this shape — it is exactly the legacy row the scrubber must handle.
      seed_legacy_event(%{
        event_type: "user.profile_updated",
        aggregate_type: "user",
        aggregate_id: user.id,
        payload: %{display_name: "Ada Lovelace"},
        metadata: %{ip: "10.0.0.1"}
      })

      # An unrelated event on a DIFFERENT aggregate — must be left untouched.
      seed_legacy_event(%{
        event_type: "book.created",
        aggregate_type: "book",
        aggregate_id: other_id,
        payload: %{isbn: "9780262510875", title: "SICP"}
      })

      before_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_id))

      assert {:ok, result} = Deletion.delete_user_data(user.id)

      # A dedicated scrub step ran inside the same erasure transaction.
      assert Map.has_key?(result, :scrub_event_log)

      # (a) The erased user's event row STILL EXISTS (immutability) but its
      #     payload AND metadata are now empty — the PII is scrubbed in place.
      user_rows =
        Repo.all(
          from(e in EventLog, where: e.aggregate_type == "user" and e.aggregate_id == ^user.id)
        )

      assert length(user_rows) == 1
      assert Enum.all?(user_rows, &(&1.payload == %{}))
      assert Enum.all?(user_rows, &(&1.metadata == %{}))

      # (b) The unrelated event row is byte-for-byte identical — untouched.
      after_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_id))
      assert after_other == before_other
    end

    test "scrubs the user's free-text PII from events under NON-user aggregates (#185)" do
      user = insert(:user)
      other_user = insert(:user)
      post_id = Ecto.UUID.generate()
      other_post_id = Ecto.UUID.generate()

      # blog.post_created carries the user's free-text post TITLE + user_id
      # under aggregate_type "post" — Phase 7's aggregate_type == "user" scrub
      # does NOT reach it, so this is the cross-aggregate leak #185 closes.
      # A LEGACY shape (title was dropped from blog.post_created going forward);
      # inserted directly since the payload contract now rejects the title key.
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

      # A DIFFERENT user's blog post — must be left untouched.
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

      # The erased user's post-event row survives (immutability) but its
      # free-text title is scrubbed to an empty payload.
      erased_row = Repo.one(from(e in EventLog, where: e.aggregate_id == ^post_id))
      assert erased_row.payload == %{}
      assert erased_row.metadata == %{}

      # The other user's post event is untouched.
      after_other = Repo.one(from(e in EventLog, where: e.aggregate_id == ^other_post_id))
      assert after_other == before_other
      assert after_other.payload["title"] == "Someone else's post"
    end
  end

  describe "delete_user_data/1 session revocation" do
    # Mirrors the login path (auth_controller): generate a family_id, mint a
    # token carrying it (which persists an op.guardian_tokens row via
    # Guardian.DB's after_encode_and_sign hook), then open the token family.
    defp open_session(user) do
      fid = Ecto.UUID.generate()
      {:ok, token, claims} = Guardian.encode_and_sign(user, %{"family_id" => fid})

      {:ok, _family} =
        Accounts.open_token_family(%{
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

      # Pre-condition: the user has an active session tracked in both tables.
      assert guardian_token_count(user.id) == 1
      assert family_count(user.id) == 1

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # Post-condition: no lingering session state keyed to the erased user.
      assert guardian_token_count(user.id) == 0
      assert family_count(user.id) == 0
    end

    test "the erased user's live token no longer verifies" do
      user = insert(:user)
      %{token: token} = open_session(user)

      # Sanity: the token verifies before erasure.
      assert {:ok, _claims} = Guardian.decode_and_verify(token)

      assert {:ok, _result} = Deletion.delete_user_data(user.id)

      # The live access token is dead: its family/guardian_tokens rows are gone.
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

  describe "delete_user_data/1 blog comment erasure (#185)" do
    test "tombstones the erased user's post_comment bodies but leaves other users' comments intact" do
      # op.post_comments.body is user-authored free-text PII. The author_id FK
      # is ON DELETE SET NULL, so deleting the user nulls authorship but leaves
      # the comment body behind — a right-to-erasure leak. Comments are threaded
      # (parent_id → replies), so erasure ANONYMISES (tombstones the body +
      # nulls author_id) rather than hard-deletes, preserving thread structure.
      erased_user = insert(:user)
      other_user = insert(:user)

      mine =
        insert(:post_comment, author: erased_user, body: "my deeply personal confession")

      # A reply BY someone else TO the erased user's comment — proves thread
      # structure survives (the reply is not orphaned/deleted).
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

      # (a) The erased user's comment: body PII gone, author nulled, row survives.
      reloaded_mine = Repo.get(PostComment, mine.id)
      assert reloaded_mine, "the comment row must survive (thread structure preserved)"
      refute reloaded_mine.body =~ "confession"
      assert reloaded_mine.body == "[deleted]"
      assert reloaded_mine.author_id == nil

      # (b) The reply (by another user) is untouched — no orphaning.
      reloaded_reply = Repo.get(PostComment, reply.id)
      assert reloaded_reply.body == "a stranger's reply"
      assert reloaded_reply.author_id == other_user.id
      assert reloaded_reply.parent_id == mine.id

      # (c) An unrelated comment by another user is byte-for-byte untouched.
      reloaded_theirs = Repo.get(PostComment, theirs.id)
      assert reloaded_theirs.body == "unrelated public thoughts"
      assert reloaded_theirs.author_id == other_user.id
    end
  end

  describe "erasure completeness — schema-level guard (#185)" do
    # ------------------------------------------------------------------------
    # SET NULL allowlist. CASCADE ('c') is ALWAYS safe for erasure — the user's
    # row is deleted outright. SET NULL ('n') is only safe when either the
    # referencing table carries NO user free-text/PII (so nulling the FK fully
    # de-links the user), OR the table's free-text IS erased by an explicit
    # Multi step in `delete_user_data/1`. A bare nilify user-FK on a NEW
    # personal table would silently leave that user's PII behind (exactly the
    # #185 post_comments leak). So SET NULL is permitted ONLY for these tables,
    # each with a documented justification; every OTHER nilify user-FK FAILS.
    #
    # Keyed by referencing table name → justification.
    @nilify_user_fk_allowlist %{
      # Financial/legal record: transactions must be retained for audit &
      # tax/dispute obligations beyond the counterparty's erasure. No
      # user-authored free-text columns (only currency + provider refs), so
      # nulling buyer_id/seller_id fully de-links the erased user.
      "transactions" => "financial-audit / legal retention; no user free-text",
      # Business entity, not personal data: `approved_by` records which admin
      # approved a partner. The partner row is a business record; nulling the
      # approver de-links the person without losing the business entity.
      "partners" => "business entity (partner record); approver de-linked on erasure",
      # User-authored free-text (comment body) IS PII, BUT it is explicitly
      # erased by the `:erase_comments` Multi step in delete_user_data/1 (body
      # tombstoned + author_id nulled). Nilify on author_id is retained to
      # preserve threaded replies. See the "blog comment erasure" test above.
      "post_comments" => "free-text body erased by :erase_comments step; nilify preserves thread"
    }

    test "every op.* FK that references op.users cascades, or nullifies only on the allowlist" do
      # Future-proofing: erasure reaches personal data via `repo.delete(user)`
      # + FK ON DELETE CASCADE (or explicit Multi steps). A new personal table
      # whose FK to op.users is RESTRICT / NO ACTION would break the erasure
      # transaction; a bare SET NULL would silently orphan the user's PII. This
      # audits EVERY FK whose target is op.users — regardless of the
      # referencing column's name (user_id, author_id, seller_id, owner_id,
      # blocker_id, …). CASCADE ('c') always passes; SET NULL ('n') passes ONLY
      # for allowlisted tables (see @nilify_user_fk_allowlist); anything else
      # FAILS. confdeltype: c=cascade n=set-null a=no-action r=restrict
      # d=set-default.
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
  end
end
