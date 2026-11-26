defmodule Stacks.Enrichment.ReviewSourcePolicyTest do
  @moduledoc """
  Reviews may come ONLY from sanctioned sources, and the
  list is enforced in the WRITE, not by convention. These prove the changeset
  refuses an unsanctioned source and a sanctioned source that links elsewhere —
  the guard the deleted implementation never had while it scraped GoodReads.
  """
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books.MockHttpClient
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

    assert "is not a sanctioned review source" in errors_on(cs).source
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

  test "a de-sanctioned source's snapshot stops being displayed, with no data migration" do
    book = insert(:book)

    {:ok, _} =
      %ReviewSnapshot{}
      |> Enrichment.review_snapshot_changeset(%{
        book_id: book.id,
        source: "open_library",
        source_url: "https://openlibrary.org/works/OL1W",
        scraped_at: DateTime.utc_now()
      })
      |> Repo.insert()

    # A row whose source was sanctioned when written and has since left the list,
    # inserted directly (the write gate refuses it now — that is the point).
    Repo.insert!(%ReviewSnapshot{
      book_id: book.id,
      source: "storygraph",
      source_url: "https://app.thestorygraph.com/books/1",
      scraped_at: DateTime.utc_now()
    })

    sources = book.id |> Enrichment.list_sanctioned_reviews() |> Enum.map(& &1.source)
    assert "open_library" in sources
    refute "storygraph" in sources
  end

  test "fetch_open_library_reviews stores a sanctioned snapshot from OL ratings, readable via the read path" do
    book = insert(:book)

    MockHttpClient.put_response(
      "openlibrary.org/works/OL1W/ratings.json",
      {:ok, %{"summary" => %{"average" => 4.2, "count" => 17}}}
    )

    assert {:ok, snap} = Enrichment.fetch_open_library_reviews(book.id, "OL1W")
    assert snap.source == "open_library"
    assert snap.rating == 4.2
    assert snap.rating_count == 17

    assert [%{source: "open_library", rating_count: 17}] =
             Enrichment.list_sanctioned_reviews(book.id)
  end

  test "fetch_open_library_reviews reports when a work has no ratings rather than storing a hollow row" do
    book = insert(:book)

    MockHttpClient.put_response(
      "openlibrary.org/works/OL2W/ratings.json",
      {:ok, %{"summary" => %{"average" => nil, "count" => 0}}}
    )

    assert {:error, :no_ratings} = Enrichment.fetch_open_library_reviews(book.id, "OL2W")
    assert Enrichment.list_sanctioned_reviews(book.id) == []
  end
end
