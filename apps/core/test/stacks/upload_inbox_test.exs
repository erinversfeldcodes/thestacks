defmodule Stacks.UploadInboxTest do
  @moduledoc """
  `Stacks.Uploads.list_awaiting_attention/1` — the predicate behind the upload
  inbox and the navigation badge (Issue #351).

  The thing under test is a *definition*, so these tests are written as the
  definition's clauses: one per branch of "is this upload still the reader's
  problem?". The interesting ones are the exclusions — an inbox that lists
  everything is easy and useless.
  """

  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Shelving
  alias Stacks.Uploads

  setup do
    %{user: insert(:user), other: insert(:user)}
  end

  defp resolved_upload(user, book_ids, opts \\ []) do
    insert(
      :uploaded_image,
      Keyword.merge(
        [
          user_id: user.id,
          status: "resolved",
          book_ids: book_ids,
          storage_path: "uploads/#{Ecto.UUID.generate()}"
        ],
        opts
      )
    )
  end

  defp rejected_upload(user, reason, opts \\ []) do
    insert(
      :uploaded_image,
      Keyword.merge(
        [
          user_id: user.id,
          status: "rejected",
          rejection_reason: reason,
          storage_path: "uploads/#{Ecto.UUID.generate()}"
        ],
        opts
      )
    )
  end

  describe "what counts as awaiting confirmation" do
    test "a resolved upload whose book the reader has not shelved is awaiting confirmation",
         %{user: user} do
      book = insert(:book)
      image = resolved_upload(user, [book.id])

      assert [item] = Uploads.list_awaiting_attention(user.id)
      assert item.image_id == image.id
      assert item.kind == "awaiting_confirmation"
      assert item.book_ids == [book.id]
      assert item.rejection_reason == nil
    end

    test "an older row that only set book_id (no book_ids array) still carries its candidate",
         %{user: user} do
      book = insert(:book)
      resolved_upload(user, [], book_id: book.id)

      assert [%{kind: "awaiting_confirmation", book_ids: [id]}] =
               Uploads.list_awaiting_attention(user.id)

      assert id == book.id
    end

    test "a multi-candidate upload keeps only the candidates the reader has not shelved",
         %{user: user} do
      shelved = insert(:book)
      unshelved = insert(:book)
      resolved_upload(user, [shelved.id, unshelved.id])
      {:ok, _} = Shelving.place_book(user.id, shelved.id, "library")

      assert [%{kind: "awaiting_confirmation", book_ids: ids}] =
               Uploads.list_awaiting_attention(user.id)

      assert ids == [unshelved.id]
    end
  end

  describe "what the inbox stops nagging about" do
    test "a resolved upload whose only book the reader already shelved is dropped",
         %{user: user} do
      book = insert(:book)
      resolved_upload(user, [book.id])
      {:ok, _} = Shelving.place_book(user.id, book.id, "wishlist")

      assert Uploads.list_awaiting_attention(user.id) == []
    end

    test "removing that placement puts the upload back — 'shelved' means an ACTIVE placement",
         %{user: user} do
      book = insert(:book)
      resolved_upload(user, [book.id])
      {:ok, placement} = Shelving.place_book(user.id, book.id, "wishlist")

      assert Uploads.list_awaiting_attention(user.id) == []

      {:ok, _} = Shelving.remove_book(placement.id, user.id)

      assert [%{kind: "awaiting_confirmation"}] = Uploads.list_awaiting_attention(user.id)
    end

    test "an in-flight upload is not in the inbox — it is awaiting the pipeline, not the reader",
         %{user: user} do
      insert(:uploaded_image, user_id: user.id, status: "pending")
      insert(:uploaded_image, user_id: user.id, status: "awaiting_upload")

      assert Uploads.list_awaiting_attention(user.id) == []
    end

    test "an upload past its 30-day expiry is not offered — the sweep is about to delete it",
         %{user: user} do
      book = insert(:book)

      resolved_upload(user, [book.id], expires_at: DateTime.add(DateTime.utc_now(), -1, :hour))

      assert Uploads.list_awaiting_attention(user.id) == []
    end
  end

  describe "failures are surfaced, and are not confirmations" do
    test "a rejected upload appears as a failure carrying the server's own reason",
         %{user: user} do
      image = rejected_upload(user, "vision_unavailable")

      assert [item] = Uploads.list_awaiting_attention(user.id)
      assert item.image_id == image.id
      assert item.kind == "failed"
      assert item.rejection_reason == "vision_unavailable"
      assert item.book_ids == []
    end

    test "a resolved upload that identified nothing is a failure, not an empty confirmation",
         %{user: user} do
      resolved_upload(user, [])

      assert [%{kind: "failed", book_ids: [], rejection_reason: nil}] =
               Uploads.list_awaiting_attention(user.id)
    end

    test "a failure never carries the awaiting_confirmation kind, however many there are",
         %{user: user} do
      book = insert(:book)
      rejected_upload(user, "not_a_book")
      rejected_upload(user, "isbn_not_found")
      resolved_upload(user, [book.id])

      items = Uploads.list_awaiting_attention(user.id)

      assert length(items) == 3
      assert Enum.count(items, &(&1.kind == "awaiting_confirmation")) == 1
      assert Enum.count(items, &(&1.kind == "failed")) == 2
    end
  end

  describe "scoping and ordering" do
    test "another reader's unfinished uploads are never returned", %{user: user, other: other} do
      book = insert(:book)
      resolved_upload(other, [book.id])
      rejected_upload(other, "not_a_book")

      assert Uploads.list_awaiting_attention(user.id) == []
      assert length(Uploads.list_awaiting_attention(other.id)) == 2
    end

    test "another reader's placement does not clear this reader's inbox item",
         %{user: user, other: other} do
      book = insert(:book)
      resolved_upload(user, [book.id])
      {:ok, _} = Shelving.place_book(other.id, book.id, "library")

      assert [%{kind: "awaiting_confirmation"}] = Uploads.list_awaiting_attention(user.id)
    end

    test "newest first", %{user: user} do
      old = rejected_upload(user, "not_a_book", uploaded_at: ~U[2026-01-01 00:00:00.000000Z])
      new = rejected_upload(user, "not_a_book", uploaded_at: ~U[2026-06-01 00:00:00.000000Z])

      assert [%{image_id: first}, %{image_id: second}] = Uploads.list_awaiting_attention(user.id)
      assert first == new.id
      assert second == old.id
    end

    test "an empty inbox is an empty list", %{user: user} do
      assert Uploads.list_awaiting_attention(user.id) == []
    end
  end

  describe "the invariant: reading the inbox places nothing" do
    @doc false
    test "listing an awaiting-confirmation upload creates no placement", %{user: user} do
      book = insert(:book)
      resolved_upload(user, [book.id])

      refute Shelving.book_on_any_shelf?(user.id, book.id)

      assert [%{kind: "awaiting_confirmation"}] = Uploads.list_awaiting_attention(user.id)
      assert [%{kind: "awaiting_confirmation"}] = Uploads.list_awaiting_attention(user.id)

      refute Shelving.book_on_any_shelf?(user.id, book.id)
      assert Shelving.get_placements_for_book(user.id, book.id) == []
    end
  end
end
