defmodule Stacks.BooksMartWiringTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  # The community read count is read with raw SQL against the mart dbt builds.
  # The query named `marts.mart_community_read_count` while dbt's
  # generate_schema_name macro materialises marts in the `marts` schema — so
  # the query could not succeed ANYWHERE, and the rescue-to-0 fallback absorbed
  # it silently: every book showed zero community reads, forever, with no error.
  #
  # This test creates the relation at the name dbt actually uses and asserts
  # the app reads a real value through it — so the schema names cannot drift
  # apart silently again.
  test "community_read_count reads the mart at the schema dbt actually builds" do
    book = insert(:book)

    Core.Repo.query!("CREATE SCHEMA IF NOT EXISTS marts")

    Core.Repo.query!("""
    CREATE TABLE IF NOT EXISTS marts.mart_community_read_count (
      book_id uuid PRIMARY KEY,
      read_count bigint NOT NULL
    )
    """)

    Core.Repo.query!(
      "INSERT INTO marts.mart_community_read_count (book_id, read_count) VALUES ($1, 7)",
      [Ecto.UUID.dump!(book.id)]
    )

    assert Stacks.Books.community_read_count(book.id) == {:ok, 7},
           "a real mart row must reach the caller — a 0 here means the query is " <>
             "aimed at a schema the mart does not live in"
  end

  # ⚠️ The three states that used to be ONE value, separated.
  #
  # This is the only place in the suite where a real mart exists, so it is the
  # only place that can tell them apart at all. Everywhere else in test there is
  # no `marts` schema, which is exactly why the old confident-zero went
  # unnoticed for so long: every assertion that could have caught it was run in
  # an environment where the failure and the answer looked identical.
  test "a mart row, an absent row, and an absent MART are three different answers" do
    book = insert(:book)
    unread = insert(:book)

    Core.Repo.query!("CREATE SCHEMA IF NOT EXISTS marts")

    Core.Repo.query!("""
    CREATE TABLE IF NOT EXISTS marts.mart_community_read_count (
      book_id uuid PRIMARY KEY,
      read_count bigint NOT NULL
    )
    """)

    Core.Repo.query!(
      "INSERT INTO marts.mart_community_read_count (book_id, read_count) VALUES ($1, 3)",
      [Ecto.UUID.dump!(book.id)]
    )

    assert Stacks.Books.community_read_count(book.id) == {:ok, 3},
           "a measured count is {:ok, n}"

    assert Stacks.Books.community_read_count(unread.id) == {:ok, 0},
           "a book the mart holds no row for has genuinely been read zero times — that is a " <>
             "real answer, not a failure, and it must be distinguishable from one"

    # Drop the mart out from under the caller: the state a stopped dbt refresh
    # leaves behind, and the one that used to be indistinguishable from
    # {:ok, 0}.
    Core.Repo.query!("DROP TABLE marts.mart_community_read_count")

    assert Stacks.Books.community_read_count(book.id) == :error,
           "with the mart gone the count cannot be read, and :error is the only honest answer. " <>
             "Returning 0 here is the defect: it reports 'nobody has read this book' for every " <>
             "book in the catalogue, forever, with nothing saying otherwise"
  end
end
