defmodule Stacks.GDPRTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.GDPR.Consent
  alias Stacks.GDPR.Deletion
  alias Stacks.GDPR.Export
  alias Stacks.GDPR.ImageRetention
  alias Stacks.Workers.ImageRetentionJob

  @export_excluded_fields [
    :password_hash,
    :email_confirmation_token,
    # Credentials behind the two links an email change is made of. Exporting them
    # would hand anyone holding the export the ability to complete or undo a change
    # — the same reason the confirmation token above is excluded. The address they
    # resolve to IS exported.
    :pending_email_token,
    :pending_email_revert_token,
    :password_reset_token,
    :email_confirmed,
    :password_reset_sent_at,
    :failed_login_count,
    :failed_login_first_at,
    :locked_until,
    :lockout_duration_seconds,
    :onboarding_completed,
    :onboarding_steps
  ]

  # The export sibling of the erasure schema-guard. Erasure walks FKs to prove
  # every user-linked row is REACHABLE; export has no cascade to lean on, so
  # each user-linked table is instead mapped, by hand, to the payload key that
  # carries it. A table that is neither mapped nor excluded-with-a-reason fails
  # the sweep — which is how a newly added user-linked table gets noticed
  # before it ships silently un-exportable.
  @export_table_roster %{
    "audit_log" => :audit_trail,
    "blog_assistant_sessions" => :writing_assistant_sessions,
    "blog_posts" => :blog_posts,
    "bookshelves" => :bookshelves,
    "embeddings" => :embeddings_summary,
    "feedback_entries" => :feedback,
    "group_invitations" => :reading_group_invitations,
    "group_members" => :reading_group_memberships,
    "groups" => :reading_groups,
    "invite_codes" => :invitations,
    "library_imports" => :library_imports,
    "listings" => :marketplace_listings,
    "offer_messages" => :marketplace_offer_messages,
    "offer_threads" => :marketplace_offer_threads,
    "post_comments" => :blog_comments,
    "transactions" => :marketplace_transactions,
    "uploaded_images" => :uploaded_images,
    "user_blocks" => :blocked_users,
    "visibility_grants" => :visibility_grants
  }

  @export_excluded_tables %{
    "admin_sessions" =>
      "operator session mechanics (hashed IP, boot id, expiry) — auth internal, not user-provided data",
    "auth_token_families" =>
      "refresh-token rotation state; a live credential, exporting it hands out session access",
    "guardian_tokens" => "issued session tokens — same credential reason as auth_token_families",
    "partners" =>
      "business-entity record; approved_by_id is an operator's action on a partner org, not their own personal data",
    "user_book_content_access" =>
      "derived access-control record, recomputable from placements; holds no user-authored content",
    "user_mfa" =>
      "TOTP secret and recovery codes are credentials; enrolment timestamps are account-security mechanics, the same class as the excluded op.users auth columns"
  }

  describe "Export.export_user_data/2" do
    test "returns a map with user data" do
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)
      assert export.user.id == user.id
      assert export.user.email == user.email
      assert Map.has_key?(export.user, :consent_analytics)
      assert Map.has_key?(export.user, :consent_writing_assistant)
      assert Map.has_key?(export.user, :consent_writing_assistant_at)
      assert is_list(export.bookshelves)
      assert is_list(export.placements)
    end

    test "includes the user's own blog posts and comments" do
      author = insert(:user)
      post = insert(:post, user: author, title: "My Post", body: "My own words.")
      insert(:post_comment, author: author, post: post, body: "My comment.")

      other = insert(:user)
      insert(:post_comment, author: other, post: post, body: "Not mine.")

      assert {:ok, export} = Export.export_user_data(author.id)

      assert [%{title: "My Post", body: "My own words."}] = export.blog_posts

      comment_bodies = Enum.map(export.blog_comments, & &1.body)
      assert "My comment." in comment_bodies
      refute "Not mine." in comment_bodies
    end

    test "includes bookshelves and placements" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, export} = Export.export_user_data(user.id)
      assert length(export.bookshelves) == 1
      assert length(export.placements) == 1
    end

    test "includes SOFT-DELETED placements — a removal does not put data beyond export" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, notes: "a margin note")

      {:ok, _} = Stacks.Shelving.remove_book(placement.id, user.id)

      assert {:ok, export} = Export.export_user_data(user.id)
      assert [exported] = export.placements
      assert exported.id == placement.id
      assert exported.removed_at != nil
      assert exported.notes == "a margin note"
    end

    test "returns error for unknown user" do
      assert {:error, _} = Export.export_user_data(Ecto.UUID.generate())
    end

    test "includes library imports with their raw rows while in retention" do
      user = insert(:user)

      csv =
        "Title,Author,ISBN13,Exclusive Shelf,My Review,Private Notes\n" <>
          "1984,George Orwell,\"=\"\"9780141036144\"\"\",read,my honest review,my private note\n"

      {:ok, _} = Stacks.Imports.create_import(user.id, "export.csv", csv)

      assert {:ok, export} = Export.export_user_data(user.id)
      assert [import_export] = export.library_imports
      assert import_export.filename == "export.csv"
      assert import_export.row_count == 1

      assert [row] = import_export.rows
      assert row.review == "my honest review"
      assert row.private_notes == "my private note"
    end

    test "carries the reader's own audit rows, with metadata readable and the ip digest withheld" do
      user = insert(:user)
      other = insert(:user)

      Stacks.Audit.log(user.id, "placement.created",
        resource_type: "placement",
        ip: "197.87.142.19",
        metadata: %{bookshelf: "library"}
      )

      Stacks.Audit.log(other.id, "placement.created",
        resource_type: "placement",
        metadata: %{bookshelf: "wishlist"}
      )

      assert {:ok, export} = Export.export_user_data(user.id)

      assert [row] = export.audit_trail,
             "expected exactly the reader's own audit row, never another reader's"

      assert row.action == "placement.created"
      assert row.resource_type == "placement"
      assert row.occurred_at

      # Stored as ciphertext to protect it at rest, not to keep it from its owner.
      assert row.metadata == %{"bookshelf" => "library"}

      # The ip digest is withheld on purpose: it tells the reader nothing they do
      # not know, and hands an interceptor a value matchable against the column.
      refute Map.has_key?(row, :ip_address)
      refute Map.has_key?(row, :operator_session_id)
    end

    test "payload contains all 25 documented keys" do
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)

      assert MapSet.new(Map.keys(export)) ==
               MapSet.new([
                 :exported_at,
                 :user,
                 :audit_trail,
                 :bookshelves,
                 :placements,
                 :placement_history,
                 :writing_assistant_sessions,
                 :writing_assistant_feedback,
                 :embeddings_summary,
                 :uploaded_images,
                 :blog_posts,
                 :blog_comments,
                 :invitations,
                 :library_imports,
                 :blog_syndications,
                 :feedback,
                 :marketplace_listings,
                 :marketplace_offer_threads,
                 :marketplace_offer_messages,
                 :marketplace_transactions,
                 :reading_groups,
                 :reading_group_memberships,
                 :reading_group_invitations,
                 :blocked_users,
                 :visibility_grants
               ])
    end

    test "includes the user's uploaded images as metadata only — never storage_path or a URL" do
      user = insert(:user)

      image =
        Repo.insert!(%Stacks.Books.UploadedImage{
          user_id: user.id,
          storage_path: "uploads/secret-key-#{user.id}",
          status: "resolved",
          uploaded_at: ~U[2026-01-02 03:04:05.000000Z],
          expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
        })

      other = insert(:user)

      Repo.insert!(%Stacks.Books.UploadedImage{
        user_id: other.id,
        storage_path: "uploads/theirs",
        status: "pending",
        uploaded_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      })

      assert {:ok, export} = Export.export_user_data(user.id)
      assert [entry] = export.uploaded_images

      assert MapSet.new(Map.keys(entry)) == MapSet.new([:id, :uploaded_at, :status])
      assert entry.id == image.id
      assert entry.status == "resolved"
      assert entry.uploaded_at == ~U[2026-01-02 03:04:05.000000Z]

      refute Map.has_key?(entry, :storage_path)

      assert {:ok, json} = Jason.encode(export)
      refute json =~ "secret-key"
      refute json =~ "uploads/"
    end

    test "includes only the user's writing-assistant sessions and feedback" do
      user = insert(:user)
      session = insert(:blog_assistant_session, user: user, topic: "My draft post")
      insert(:turn_feedback, session: session, rating: "up", comment: "Great help.")

      other = insert(:user)
      other_session = insert(:blog_assistant_session, user: other)
      insert(:turn_feedback, session: other_session)

      assert {:ok, export} = Export.export_user_data(user.id)

      assert [exported_session] = export.writing_assistant_sessions
      assert exported_session.id == session.id
      assert exported_session.topic == "My draft post"

      assert [exported_feedback] = export.writing_assistant_feedback
      assert exported_feedback.session_id == session.id
      assert exported_feedback.rating == "up"
      assert exported_feedback.comment == "Great help."
    end

    test "embeddings_summary lists metadata but NEVER the raw vector" do
      user = insert(:user)
      sentinel = 0.4242
      vector = List.duplicate(sentinel, 1024)

      insert(:embedding,
        user: user,
        source_type: "shelf",
        title: "The Name of the Rose",
        shelf: "library",
        content_date: ~U[2026-01-02 03:04:05.000000Z],
        embedding: Pgvector.new(vector)
      )

      assert {:ok, export} = Export.export_user_data(user.id)
      assert [entry] = export.embeddings_summary

      assert MapSet.new(Map.keys(entry)) ==
               MapSet.new([:source_type, :source_title, :shelf, :date_embedded])

      assert entry.source_type == "shelf"
      assert entry.source_title == "The Name of the Rose"
      assert entry.shelf == "library"
      assert entry.date_embedded == ~U[2026-01-02 03:04:05.000000Z]

      refute Map.has_key?(entry, :embedding)

      refute Enum.any?(Map.values(entry), fn v ->
               match?(%Pgvector{}, v) or (is_list(v) and sentinel in v)
             end)

      assert {:ok, json} = Jason.encode(export)
      refute json =~ "0.4242"
    end

    test "embeddings_summary and writing-assistant keys default to empty lists" do
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)
      assert export.writing_assistant_sessions == []
      assert export.writing_assistant_feedback == []
      assert export.embeddings_summary == []
    end

    test "exports the settings personal-data fields verbatim" do
      user =
        insert(:user,
          handle: "night_reader",
          website_url: "https://myblog.example.com",
          country_code: "GB",
          city: "Edinburgh",
          notify_wishlist_availability: true,
          notify_marketplace: false,
          notify_group_invitations: false,
          notify_event_matches: true
        )

      assert {:ok, export} = Export.export_user_data(user.id)

      assert export.user.handle == "night_reader"
      assert export.user.website_url == "https://myblog.example.com"
      assert export.user.country_code == "GB"
      assert export.user.city == "Edinburgh"
      assert export.user.notify_wishlist_availability == true
      assert export.user.notify_marketplace == false
      assert export.user.notify_group_invitations == false
      assert export.user.notify_event_matches == true
    end

    test "every personal user-schema field appears in the export (schema-sweep guard)" do
      # Mirrors the erasure schema-level guard: a future column added to
      # op.users fails this test until it is either exported by
      # Export.export_user_data/2 or added to @export_excluded_fields WITH a
      # written rationale. Prevents a new personal field silently escaping export.
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)
      exported_keys = MapSet.new(Map.keys(export.user))

      missing =
        for field <- User.__schema__(:fields),
            field not in @export_excluded_fields,
            not MapSet.member?(exported_keys, field),
            do: field

      assert missing == [],
             "op.users personal fields missing from GDPR export: #{inspect(missing)}. " <>
               "Add each to Export.export_user_data/2's user map, or add it to " <>
               "@export_excluded_fields WITH a written rationale if it is a secret, " <>
               "account-security mechanic, or internal UX flag."
    end
  end

  describe "export completeness — table-level guard" do
    defp user_linked_tables do
      {:ok, %{rows: rows}} =
        Repo.query("""
        SELECT DISTINCT c.relname
        FROM information_schema.table_constraints tc
        JOIN information_schema.constraint_column_usage ccu
          ON ccu.constraint_name = tc.constraint_name
         AND ccu.constraint_schema = tc.constraint_schema
        JOIN pg_class c ON c.relname = tc.table_name
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = tc.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = 'op'
          AND ccu.table_schema = 'op'
          AND ccu.table_name = 'users'
        ORDER BY 1
        """)

      rows |> List.flatten() |> MapSet.new()
    end

    # The FK sweep above cannot see `audit.audit_log`, twice over: it lives in the
    # `audit` schema, and it deliberately carries no foreign key to op.users so the
    # trail survives erasure. A table that is invisible to the guard is a table that
    # can be forgotten, which is exactly how the audit log stayed out of the export
    # without anyone deciding it should. So discovery is widened: ANY table in `op`
    # or `audit` naming a user_id column is in scope, FK or not.
    defp user_column_tables do
      {:ok, %{rows: rows}} =
        Repo.query("""
        SELECT DISTINCT c.table_name
        FROM information_schema.columns c
        WHERE c.table_schema IN ('op', 'audit')
          AND c.column_name = 'user_id'
        ORDER BY 1
        """)

      rows |> List.flatten() |> MapSet.new()
    end

    test "every op.* table linked to op.users is exported, or excluded with a reason" do
      accounted =
        MapSet.union(
          MapSet.new(Map.keys(@export_table_roster)),
          MapSet.new(Map.keys(@export_excluded_tables))
        )

      unaccounted =
        user_linked_tables()
        |> MapSet.union(user_column_tables())
        |> MapSet.difference(accounted)
        |> Enum.sort()

      assert unaccounted == [],
             "op.*/audit.* tables naming a user that GDPR export neither carries nor " <>
               "excludes: #{inspect(unaccounted)}. Personal data belongs in " <>
               "Export.export_user_data/2 under a payload key, listed in @export_table_roster. " <>
               "Only credentials, session mechanics, business-entity records and derived rows " <>
               "belong in @export_excluded_tables, each with its reason on the same line."
    end

    test "every roster entry names a key the export payload actually has" do
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)
      payload_keys = MapSet.new(Map.keys(export))

      dangling =
        @export_table_roster
        |> Enum.reject(fn {_table, key} -> MapSet.member?(payload_keys, key) end)
        |> Enum.map(fn {table, key} -> "#{table} -> #{key}" end)
        |> Enum.sort()

      assert dangling == [],
             "@export_table_roster maps tables to payload keys that export_user_data/2 does not " <>
               "produce: #{inspect(dangling)}. The roster is only a guard while every key in it " <>
               "is real — a renamed key must be renamed here too."
    end

    test "no table is both rostered and excluded, and every exclusion carries a reason" do
      both =
        @export_table_roster
        |> Map.keys()
        |> Enum.filter(&Map.has_key?(@export_excluded_tables, &1))

      assert both == [], "tables both exported and excluded: #{inspect(both)}"

      blank =
        for {table, reason} <- @export_excluded_tables,
            not is_binary(reason) or String.trim(reason) == "",
            do: table

      assert blank == [], "@export_excluded_tables entries with no reason: #{inspect(blank)}"
    end
  end

  describe "warehouse exclusions" do
    # `mix proto.sync` will happily put a column back into a staging view the
    # moment someone drops its `dbt_exclude`, and the drift check would call
    # that correct — the generator has no notion of personal data. These are
    # the columns whose absence from the warehouse is the GDPR promise, named
    # here so the promise fails loudly rather than regenerating away.
    @warehouse_forbidden_columns %{
      "stg_bookshelf_placements.sql" => ~w(notes),
      "stg_uploaded_images.sql" => ~w(storage_path),
      "stg_listings.sql" => ~w(description contact_info),
      "stg_offer_messages.sql" => ~w(body),
      "stg_transactions.sql" => ~w(payment_provider_ref shipping_provider_ref),
      "stg_invite_codes.sql" => ~w(note invited_email code_hash),
      "stg_library_imports.sql" => ~w(filename),
      "stg_users.sql" =>
        ~w(password_hash password_reset_token email_confirmation_token password_reset_sent_at failed_login_count failed_login_first_at locked_until),
      "stg_partners.sql" => ~w(hmac_secret)
    }

    defp selected_columns(model) do
      Path.join([__DIR__, "..", "..", "..", "..", "dbt", "models", "staging", model])
      |> File.read!()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s{4}(\w+),?\s*$/, line) do
          [_, column] -> [column]
          nil -> []
        end
      end)
      |> MapSet.new()
    end

    test "no staging model selects a column that must not reach the warehouse" do
      leaks =
        for {model, forbidden} <- @warehouse_forbidden_columns,
            selected = selected_columns(model),
            column <- forbidden,
            MapSet.member?(selected, column),
            do: "#{model}:#{column}"

      assert leaks == [],
             "staging models selecting columns that must stay out of the warehouse: " <>
               "#{inspect(leaks)}. Restore the column's dbt_exclude in proto/persisted.exs and " <>
               "re-run mix proto.sync — a regenerated view is still a leak."
    end
  end

  describe "Export.export_user_data/2 — marketplace and social data" do
    test "exports the user's own listings, including the free text they wrote" do
      user = insert(:user)

      insert(:listing,
        seller: user,
        description: "Spine cracked, reads fine.",
        contact_info: "dm me"
      )

      insert(:listing, seller: insert(:user), description: "Not mine.")

      assert {:ok, export} = Export.export_user_data(user.id)
      assert [listing] = export.marketplace_listings
      assert listing.description == "Spine cracked, reads fine."
      assert listing.contact_info == "dm me"
    end

    test "exports the offer messages the user sent, but not the counterparty's" do
      user = insert(:user)
      thread = insert(:offer_thread, buyer: user)
      insert(:offer_message, thread: thread, sender: user, body: "Would you take 100?")
      insert(:offer_message, thread: thread, sender: insert(:user), body: "No, sorry.")

      assert {:ok, export} = Export.export_user_data(user.id)

      assert [%{status: "open"}] = export.marketplace_offer_threads
      assert Enum.map(export.marketplace_offer_messages, & &1.body) == ["Would you take 100?"]
    end

    test "exports transactions on both sides, labelled with the user's role" do
      buyer = insert(:user)
      insert(:transaction, buyer: buyer)

      assert {:ok, export} = Export.export_user_data(buyer.id)
      assert [txn] = export.marketplace_transactions
      assert txn.role == "buyer"
      assert txn.amount_cents == 15_000
      refute Map.has_key?(txn, :payment_provider_ref)
    end

    test "exports groups the user owns and their own memberships, not the roster" do
      user = insert(:user)
      insert(:group, owner: user, name: "Tuesday Readers")
      other_group = insert(:group, owner: insert(:user))
      insert(:group_member, group: other_group, user: user, role: "member")
      insert(:group_member, group: other_group, user: insert(:user), role: "member")

      assert {:ok, export} = Export.export_user_data(user.id)

      assert [%{name: "Tuesday Readers"}] = export.reading_groups
      assert [membership] = export.reading_group_memberships
      assert membership.group_id == other_group.id
    end

    test "exports group invitations in both directions, labelled" do
      user = insert(:user)
      insert(:group_invitation, invited_user: user)
      insert(:group_invitation, invited_by_user: user)

      assert {:ok, export} = Export.export_user_data(user.id)

      assert Enum.sort(Enum.map(export.reading_group_invitations, & &1.direction)) ==
               ["received", "sent"]
    end

    test "exports the user's own block list, never who has blocked them" do
      user = insert(:user)
      blocked = insert(:user)
      insert(:user_block, blocker: user, blocked: blocked)
      insert(:user_block, blocker: insert(:user), blocked: user)

      assert {:ok, export} = Export.export_user_data(user.id)
      assert [entry] = export.blocked_users
      assert entry.blocked_id == blocked.id
    end

    test "exports visibility grants the user made and received, labelled" do
      user = insert(:user)
      insert(:visibility_grant, granted_by: user)
      insert(:visibility_grant, granted_to: user)

      assert {:ok, export} = Export.export_user_data(user.id)

      assert Enum.sort(Enum.map(export.visibility_grants, & &1.direction)) ==
               ["granted", "received"]
    end
  end

  describe "Deletion.delete_user_data/1" do
    test "removes all user data" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, _} = Deletion.delete_user_data(user.id)
      assert nil == Repo.get(User, user.id)
    end

    test "erases SOFT-DELETED placements too — a removal does not hide a row from erasure" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, notes: "a margin note")

      {:ok, _} = Stacks.Shelving.remove_book(placement.id, user.id)
      assert Repo.get(Stacks.Shelving.Placement, placement.id) != nil

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      assert nil == Repo.get(Stacks.Shelving.Placement, placement.id)
    end

    test "removes placement history for user's bookshelves" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book)
      to_bookshelf = insert(:bookshelf, user: insert(:user), name: "wishlist")

      {:ok, id_bin} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, book_id_bin} = Ecto.UUID.dump(book.id)
      {:ok, from_bin} = Ecto.UUID.dump(bookshelf.id)
      {:ok, to_bin} = Ecto.UUID.dump(to_bookshelf.id)

      Core.Repo.insert_all(
        "bookshelf_placement_history",
        [
          %{
            id: id_bin,
            book_id: book_id_bin,
            from_bookshelf: from_bin,
            to_bookshelf: to_bin,
            moved_at: DateTime.utc_now()
          }
        ],
        prefix: "op"
      )

      assert {:ok, _} = Deletion.delete_user_data(user.id)
    end

    test "erases library imports AND their raw rows — the reader's Goodreads free text" do
      user = insert(:user)

      csv =
        "Title,Author,ISBN13,Exclusive Shelf,My Review,Private Notes\n" <>
          "1984,George Orwell,\"=\"\"9780141036144\"\"\",read,my honest review,my private note\n"

      {:ok, import} = Stacks.Imports.create_import(user.id, "export.csv", csv)

      assert {:ok, preview} = Deletion.preview_user_data(user.id)
      assert preview.library_imports == 1

      assert {:ok, result} = Deletion.delete_user_data(user.id)
      assert result.delete_library_imports == 1

      assert nil == Repo.get(Stacks.Imports.LibraryImport, import.id)

      assert [] ==
               Repo.all(
                 from(r in Stacks.Imports.LibraryImportRow, where: r.import_id == ^import.id)
               )
    end
  end

  describe "Consent.grant_consent/2" do
    test "sets consent_analytics to true and records timestamp" do
      user = insert(:user, consent_analytics: false)
      assert {:ok, updated} = Consent.grant_consent(user.id)
      assert updated.consent_analytics == true
      assert updated.consent_analytics_at != nil
    end
  end

  describe "Consent.revoke_consent/2" do
    test "sets consent_analytics to false" do
      user = insert(:user, consent_analytics: true)
      assert {:ok, updated} = Consent.revoke_consent(user.id)
      assert updated.consent_analytics == false
    end
  end

  describe "Consent.check_consent/2" do
    test "returns true when consent is granted" do
      user = insert(:user, consent_analytics: true)
      assert Consent.check_consent(user.id) == true
    end

    test "returns false when consent is not granted" do
      user = insert(:user, consent_analytics: false)
      assert Consent.check_consent(user.id) == false
    end

    test "returns false for unknown user" do
      assert Consent.check_consent(Ecto.UUID.generate()) == false
    end
  end

  describe "ImageRetention.cleanup_expired_images/0" do
    test "deletes images with expires_at in the past" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)
      future = DateTime.add(now, 3600, :second)

      {:ok, past_bin} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, future_bin} = Ecto.UUID.dump(Ecto.UUID.generate())
      book = insert(:book)
      {:ok, book_id_bin} = Ecto.UUID.dump(book.id)

      Core.Repo.insert_all(
        "uploaded_images",
        [
          %{
            id: past_bin,
            book_id: book_id_bin,
            status: "pending",
            uploaded_at: past,
            expires_at: past,
            created_at: now,
            updated_at: now
          },
          %{
            id: future_bin,
            book_id: book_id_bin,
            status: "pending",
            uploaded_at: now,
            expires_at: future,
            created_at: now,
            updated_at: now
          }
        ],
        prefix: "op"
      )

      assert {:ok, 1} = ImageRetention.cleanup_expired_images()
    end
  end

  describe "ImageRetention.cleanup_stuck_images/0" do
    test "deletes images stuck in pending for over 2 hours" do
      now = DateTime.utc_now()
      stuck_at = DateTime.add(now, -3 * 3600, :second)

      {:ok, stuck_bin} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, recent_bin} = Ecto.UUID.dump(Ecto.UUID.generate())
      book = insert(:book)
      {:ok, book_id_bin} = Ecto.UUID.dump(book.id)

      Core.Repo.insert_all(
        "uploaded_images",
        [
          %{
            id: stuck_bin,
            book_id: book_id_bin,
            status: "pending",
            uploaded_at: stuck_at,
            expires_at: DateTime.add(stuck_at, 86_400, :second),
            created_at: stuck_at,
            updated_at: stuck_at
          },
          %{
            id: recent_bin,
            book_id: book_id_bin,
            status: "pending",
            uploaded_at: now,
            expires_at: DateTime.add(now, 86_400, :second),
            created_at: now,
            updated_at: now
          }
        ],
        prefix: "op"
      )

      assert {:ok, 1} = ImageRetention.cleanup_stuck_images()
    end
  end

  describe "ImageRetentionJob" do
    test "perform/1 calls cleanup_stuck_images and cleanup_expired_images" do
      assert :ok = ImageRetentionJob.perform(%Oban.Job{args: %{}})
    end
  end
end
