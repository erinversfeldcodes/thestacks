defmodule Stacks.BooksMartWiringTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  # The community read count is read with raw SQL against the mart dbt builds.
  # The query named `wh.mart_community_read_count` while dbt's
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

    assert Stacks.Books.community_read_count(book.id) == 7,
           "a real mart row must reach the caller — a 0 here means the query is " <>
             "aimed at a schema the mart does not live in"
  end
end
