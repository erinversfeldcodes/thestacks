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

  describe "Export.export_user_data/2" do
    test "returns a map with user data" do
      user = insert(:user)
      assert {:ok, export} = Export.export_user_data(user.id)
      assert export.user.id == user.id
      assert export.user.email == user.email
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
