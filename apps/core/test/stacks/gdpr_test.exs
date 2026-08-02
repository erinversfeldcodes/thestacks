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

  # op.users columns deliberately NOT in the GDPR export (mirrors the
  # exclusion rationale in Stacks.GDPR.Export's user map). Secrets, account-
  # security mechanics, and internal UX progress flags — none are user-provided
  # personal data the subject is entitled to receive. Every OTHER real schema
  # field MUST appear in the export or this guard fails.
  @export_excluded_fields [
    # Secrets — exporting would leak credentials / defeat their purpose.
    :password_hash,
    :email_confirmation_token,
    :password_reset_token,
    # Account-security mechanics — internal auth state, not personal data.
    :email_confirmed,
    :password_reset_sent_at,
    :failed_login_count,
    :failed_login_first_at,
    :locked_until,
    # Internal UX progress flags — app state, not personal data.
    :onboarding_completed,
    :onboarding_steps
  ]

  describe "Export.export_user_data/2" do
    test "returns a map with user data" do
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)
      assert export.user.id == user.id
      assert export.user.email == user.email
      # Both consent flags are portable (writing-assistant added alongside analytics).
      assert Map.has_key?(export.user, :consent_analytics)
      assert Map.has_key?(export.user, :consent_writing_assistant)
      assert Map.has_key?(export.user, :consent_writing_assistant_at)
      assert is_list(export.bookshelves)
      assert is_list(export.placements)
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

    # ── #375: soft-deleted placements are still the subject's data ──────────
    #
    # `remove_book/2` stamps `removed_at` and leaves the row; #375's undo clears
    # it again. Both states are personal data the subject is entitled to receive,
    # and a removed row is the one most easily forgotten — it is invisible to
    # every browse query in the app (`is_nil(removed_at)` filters). Asserted
    # rather than reasoned from `Export`'s query having no filter, because "the
    # query looks right" is how the #185 post_comments gap survived seven
    # reviews.
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
      # The free text on the removed row is exported too, not silently dropped.
      assert exported.notes == "a margin note"
    end

    test "returns error for unknown user" do
      assert {:error, _} = Export.export_user_data(Ecto.UUID.generate())
    end

    test "payload contains all 8 documented keys" do
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)

      assert MapSet.new(Map.keys(export)) ==
               MapSet.new([
                 :exported_at,
                 :user,
                 :bookshelves,
                 :placements,
                 :placement_history,
                 :writing_assistant_sessions,
                 :writing_assistant_feedback,
                 :embeddings_summary
               ])
    end

    test "includes only the user's writing-assistant sessions and feedback" do
      user = insert(:user)
      session = insert(:blog_assistant_session, user: user, topic: "My draft post")
      insert(:turn_feedback, session: session, rating: "up", comment: "Great help.")

      # Another user's data must NOT leak in.
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
      # Seed a real, distinctive vector so the no-leak assertion is non-vacuous.
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

      # Only the four documented, human-readable fields — nothing else.
      assert MapSet.new(Map.keys(entry)) ==
               MapSet.new([:source_type, :source_title, :shelf, :date_embedded])

      assert entry.source_type == "shelf"
      assert entry.source_title == "The Name of the Rose"
      assert entry.shelf == "library"
      assert entry.date_embedded == ~U[2026-01-02 03:04:05.000000Z]

      # The raw vector must not appear under any key…
      refute Map.has_key?(entry, :embedding)

      refute Enum.any?(Map.values(entry), fn v ->
               match?(%Pgvector{}, v) or (is_list(v) and sentinel in v)
             end)

      # …nor anywhere in the JSON-serialised export the user downloads.
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

    test "exports the settings personal-data fields verbatim (#299)" do
      # The four notify_* prefs, website_url, country_code, city and handle are
      # all written by the settings screens; a data export must return them.
      # Each value below is NON-DEFAULT (flips the schema default) so the
      # assertion fails against a map that omits the field OR hardcodes a default.
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

    test "every personal user-schema field appears in the export (schema-sweep guard, #299)" do
      # Mirrors the erasure schema-level guard (#185): a future column added to
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

  describe "Deletion.delete_user_data/1" do
    test "removes all user data" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, _} = Deletion.delete_user_data(user.id)
      assert nil == Repo.get(User, user.id)
    end

    # ── #375 ──────────────────────────────────────────────────────────────
    test "erases SOFT-DELETED placements too — a removal does not hide a row from erasure" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)
      placement = insert(:placement, bookshelf: bookshelf, book: book, notes: "a margin note")

      {:ok, _} = Stacks.Shelving.remove_book(placement.id, user.id)
      # Pre-condition: the row survived the removal (that is what soft-delete
      # means), so erasure has something left to erase.
      assert Repo.get(Stacks.Shelving.Placement, placement.id) != nil

      assert {:ok, _} = Deletion.delete_user_data(user.id)

      # The row — and the free text on it — is gone, not merely author-nulled.
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
      # No images to clean up — should return :ok without error
      assert :ok = ImageRetentionJob.perform(%Oban.Job{args: %{}})
    end
  end
end
