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
    :password_reset_token,
    :email_confirmed,
    :password_reset_sent_at,
    :failed_login_count,
    :failed_login_first_at,
    :locked_until,
    :onboarding_completed,
    :onboarding_steps
  ]

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

    test "payload contains all 15 documented keys" do
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
                 :embeddings_summary,
                 :uploaded_images,
                 :blog_posts,
                 :blog_comments,
                 :invitations,
                 :library_imports,
                 :blog_syndications,
                 :feedback
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

    test "every personal user-schema field appears in the export (schema-sweep guard, )" do
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
