defmodule Stacks.FeedsTest do
  @moduledoc """
  Tests for Stacks.Feeds context — Atom feed generation for public bookshelves.
  """

  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Feeds

  describe "generate_atom/2" do
    test "returns {:ok, xml, etag} for a platform-visible bookshelf" do
      user = insert(:user, display_name: "Erin")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      author = insert(:author, name: "Donna Tartt")
      book = insert(:book, title: "The Secret History", author: author)
      _edition = insert(:book_edition, book: book, isbn: "9780140167771", is_primary: true)
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, etag} = Feeds.generate_atom(user.id, "library")

      assert is_binary(xml)
      assert is_binary(etag)
      assert String.contains?(xml, "Erin")
      assert String.contains?(xml, "The Secret History")
      assert String.contains?(xml, "Donna Tartt")
      assert String.contains?(xml, "9780140167771")
      assert String.contains?(xml, "application/atom+xml") == false
      assert String.contains?(xml, "<feed xmlns=")
      assert String.contains?(xml, "<entry>")
    end

    test "returns {:error, :not_found} for nonexistent bookshelf" do
      assert {:error, :not_found} = Feeds.generate_atom(Ecto.UUID.generate(), "library")
    end

    test "returns {:error, :not_public} for owner-visibility bookshelf" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "owner")

      assert {:error, :not_public} = Feeds.generate_atom(user.id, "library")
    end

    test "returns {:error, :not_public} for group-visibility bookshelf" do
      user = insert(:user)
      _bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "group")

      assert {:error, :not_public} = Feeds.generate_atom(user.id, "library")
    end

    test "returns valid XML with empty bookshelf" do
      user = insert(:user, display_name: "Test User")
      _bookshelf = insert(:bookshelf, user: user, name: "wishlist", visibility: "platform")

      assert {:ok, xml, _etag} = Feeds.generate_atom(user.id, "wishlist")
      assert String.contains?(xml, "<feed xmlns=")
      assert String.contains?(xml, "Test User")
      refute String.contains?(xml, "<entry>")
    end

    test "escapes XML special characters in titles" do
      user = insert(:user, display_name: "A & B <User>")
      bookshelf = insert(:bookshelf, user: user, name: "library", visibility: "platform")
      book = insert(:book, title: "Tom & Jerry <Adventures>")
      _placement = insert(:placement, bookshelf: bookshelf, book: book)

      assert {:ok, xml, _etag} = Feeds.generate_atom(user.id, "library")
      assert String.contains?(xml, "&amp;")
      assert String.contains?(xml, "&lt;")
    end
  end

  describe "compute_etag/1" do
    test "returns consistent MD5 hash for same content" do
      xml = "<feed>test</feed>"
      etag1 = Feeds.compute_etag(xml)
      etag2 = Feeds.compute_etag(xml)
      assert etag1 == etag2
      assert String.length(etag1) == 32
    end

    test "returns different hash for different content" do
      etag1 = Feeds.compute_etag("<feed>one</feed>")
      etag2 = Feeds.compute_etag("<feed>two</feed>")
      refute etag1 == etag2
    end
  end
end
