defmodule Stacks.Enrichment.AuthorsTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Enrichment.Authors

  describe "update_author_sources/2" do
    test "updates website_url on an author" do
      author = insert(:author)

      assert {:ok, updated} =
               Authors.update_author_sources(author, %{website_url: "https://author.com"})

      assert updated.website_url == "https://author.com"
    end

    test "updates rss_feed_url on an author" do
      author = insert(:author)

      assert {:ok, updated} =
               Authors.update_author_sources(author, %{rss_feed_url: "https://author.com/feed"})

      assert updated.rss_feed_url == "https://author.com/feed"
    end

    test "updates both website_url and rss_feed_url" do
      author = insert(:author)

      assert {:ok, updated} =
               Authors.update_author_sources(author, %{
                 website_url: "https://author.com",
                 rss_feed_url: "https://author.com/feed"
               })

      assert updated.website_url == "https://author.com"
      assert updated.rss_feed_url == "https://author.com/feed"
    end
  end

  describe "authors_without_sources/0" do
    test "returns authors missing website_url" do
      author = insert(:author, website_url: nil, rss_feed_url: "https://example.com/feed")

      _complete =
        insert(:author,
          website_url: "https://example.com",
          rss_feed_url: "https://example.com/feed"
        )

      result = Authors.authors_without_sources()
      ids = Enum.map(result, & &1.id)

      assert author.id in ids
    end

    test "returns authors missing rss_feed_url" do
      author = insert(:author, website_url: "https://example.com", rss_feed_url: nil)

      result = Authors.authors_without_sources()
      ids = Enum.map(result, & &1.id)

      assert author.id in ids
    end

    test "excludes authors with both sources set" do
      _complete =
        insert(:author,
          website_url: "https://example.com",
          rss_feed_url: "https://example.com/feed"
        )

      result = Authors.authors_without_sources()
      assert result == []
    end
  end

  describe "authors_with_rss/0" do
    test "returns authors with rss_feed_url set" do
      author = insert(:author, rss_feed_url: "https://example.com/feed")
      _no_rss = insert(:author, rss_feed_url: nil)

      result = Authors.authors_with_rss()
      ids = Enum.map(result, & &1.id)

      assert author.id in ids
      assert length(result) == 1
    end

    test "returns empty list when no authors have rss" do
      insert(:author, rss_feed_url: nil)
      assert Authors.authors_with_rss() == []
    end
  end

  describe "get_author/1" do
    test "returns author by id" do
      author = insert(:author)
      assert Authors.get_author(author.id).id == author.id
    end

    test "returns nil for non-existent id" do
      assert is_nil(Authors.get_author(Ecto.UUID.generate()))
    end
  end
end
