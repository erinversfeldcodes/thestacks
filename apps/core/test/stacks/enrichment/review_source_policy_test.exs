defmodule Stacks.Enrichment.ReviewSourcePolicyTest do
  @moduledoc """
  US-2.1.1 §4 (ruling D6): reviews may come ONLY from sanctioned sources, and the
  list is enforced in the WRITE, not by convention. These prove the changeset
  refuses an unsanctioned source and a sanctioned source that links elsewhere —
  the guard the deleted implementation never had while it scraped GoodReads.
  """
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Enrichment
  alias Stacks.Enrichment.ReviewSnapshot

  defp attrs(overrides) do
    book = insert(:book)

    %{
      book_id: book.id,
      source: "open_library",
      source_url: "https://openlibrary.org/works/OL1W",
      scraped_at: DateTime.utc_now()
    }
    |> Map.merge(Map.new(overrides))
  end

  test "an unsanctioned source is refused even by a caller that means to persist it" do
    cs = Enrichment.review_snapshot_changeset(%ReviewSnapshot{}, attrs(source: "goodreads"))

    refute cs.valid?

    assert "is not a sanctioned review source (US-2.1.1 §4, ruling D6)" in errors_on(cs).source
  end

  test "a snapshot may not claim a sanctioned source while linking to another host" do
    cs =
      Enrichment.review_snapshot_changeset(
        %ReviewSnapshot{},
        attrs(source: "open_library", source_url: "https://www.goodreads.com/book/show/1")
      )

    refute cs.valid?
    assert Enum.any?(errors_on(cs).source_url, &(&1 =~ "host does not belong"))
  end

  test "a sanctioned source linking to its own host is accepted" do
    assert Enrichment.review_snapshot_changeset(
             %ReviewSnapshot{},
             attrs(source: "open_library", source_url: "https://openlibrary.org/works/OL1W")
           ).valid?

    # subdomain of a pinned host is still the same source
    assert Enrichment.review_snapshot_changeset(
             %ReviewSnapshot{},
             attrs(source: "reddit", source_url: "https://www.reddit.com/r/books/comments/x")
           ).valid?
  end

  test "a variable-host sanctioned source (author_rss) needs only a well-formed URL" do
    assert Enrichment.review_snapshot_changeset(
             %ReviewSnapshot{},
             attrs(source: "author_rss", source_url: "https://someauthor.example/feed.xml")
           ).valid?

    refute Enrichment.review_snapshot_changeset(
             %ReviewSnapshot{},
             attrs(source: "author_rss", source_url: "not a url")
           ).valid?
  end
end
