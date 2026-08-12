defmodule Stacks.ShelvingQueryTest do
  @moduledoc """
      Query-plan and query-count guards for the shelf-browse read path: index sanity (the browse predicates are servable by real,
      still-existing indexes — asserted via EXPLAIN) and no-N+1
      (`get_bookshelf_shelves/2` issues a bounded query count regardless of
      shelf/placement count, counted via a telemetry handler).
  """

  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Ecto.Adapters.SQL
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement}

  @bookshelves_idx "bookshelves_user_id_name_index"
  @placements_active_idx "bookshelf_placements_book_active_idx"
  @placements_bookshelf_idx "bookshelf_placements_bookshelf_id_index"

  describe "index definitions (migration drift guard)" do
    test "op.bookshelves has a unique index on (user_id, name)" do
      assert %{rows: [[indexdef]]} =
               Repo.query!(
                 "SELECT indexdef FROM pg_indexes WHERE schemaname = 'op' AND tablename = 'bookshelves' AND indexname = $1",
                 [@bookshelves_idx]
               )

      assert indexdef =~ "UNIQUE INDEX"
      assert indexdef =~ "(user_id, name)"
    end

    test "op.bookshelf_placements has a partial unique index restricted to active rows" do
      assert %{rows: [[indexdef]]} =
               Repo.query!(
                 "SELECT indexdef FROM pg_indexes WHERE schemaname = 'op' AND tablename = 'bookshelf_placements' AND indexname = $1",
                 [@placements_active_idx]
               )

      assert indexdef =~ "UNIQUE INDEX"
      assert indexdef =~ "(book_id, bookshelf_id)"
      assert indexdef =~ "WHERE (removed_at IS NULL)"
    end

    test "op.bookshelf_placements has an index on the bookshelf_id FK" do
      assert %{rows: [[_indexdef]]} =
               Repo.query!(
                 "SELECT indexdef FROM pg_indexes WHERE schemaname = 'op' AND tablename = 'bookshelf_placements' AND indexname = $1",
                 [@placements_bookshelf_idx]
               )
    end
  end

  describe "query plans" do
    setup do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      shelf = insert(:shelf, bookshelf: bookshelf, position: 0)

      for _ <- 1..5 do
        insert(:placement, bookshelf: bookshelf, shelf: shelf, book: insert(:book))
      end

      {:ok, user: user, bookshelf: bookshelf}
    end

    test "bookshelf lookup by (user_id, name) is served by the unique index", %{user: user} do
      query =
        from(b in Bookshelf, where: b.user_id == ^user.id and b.name == ^"library", select: b.id)

      plan = explain_without_seqscan(query)

      assert plan =~ @bookshelves_idx,
             """
             Expected the (user_id, name) lookup to be servable by #{@bookshelves_idx}.
             Plan was:
             #{plan}
             """
    end

    test "the active-placement filter is served by the partial index, not a seq scan", %{
      bookshelf: bookshelf
    } do
      query =
        from(p in Placement,
          where: p.bookshelf_id == ^bookshelf.id and is_nil(p.removed_at),
          select: p.id
        )

      plan = explain_without_seqscan(query)

      assert plan =~ @placements_active_idx or plan =~ @placements_bookshelf_idx,
             """
             Expected the active-placement filter to be servable by
             #{@placements_active_idx} or #{@placements_bookshelf_idx}.
             Plan was:
             #{plan}
             """

      refute plan =~ "Seq Scan on bookshelf_placements",
             """
             Active-placement filter fell back to a sequential scan even with
             enable_seqscan off — no index can serve this predicate.
             Plan was:
             #{plan}
             """
    end
  end

  describe "get_bookshelf_shelves/2 query count (N+1 guard)" do
    test "query count does not grow with the number of placements" do
      small = seed_bookshelf(placements: 2, shelves: 1)
      large = seed_bookshelf(placements: 25, shelves: 1)

      {small_shelves, small_q} =
        with_query_count(fn -> Shelving.get_bookshelf_shelves(small.user_id, "library") end)

      {large_shelves, large_q} =
        with_query_count(fn -> Shelving.get_bookshelf_shelves(large.user_id, "library") end)

      assert placement_count(small_shelves) == 2
      assert placement_count(large_shelves) == 25

      assert large_q == small_q,
             """
             N+1: 25 placements cost #{large_q} queries where 2 cost #{small_q}.
             The `book: [:author, :editions]` / `bookshelf: :user` preloads in
             Shelving.active_placements_query/0 must batch, not fire per row.
             """
    end

    test "query count does not grow with the number of shelves" do
      one = seed_bookshelf(placements: 6, shelves: 1)
      many = seed_bookshelf(placements: 6, shelves: 6)

      {one_shelves, one_q} =
        with_query_count(fn -> Shelving.get_bookshelf_shelves(one.user_id, "library") end)

      {many_shelves, many_q} =
        with_query_count(fn -> Shelving.get_bookshelf_shelves(many.user_id, "library") end)

      assert length(one_shelves) == 1
      assert length(many_shelves) == 6
      assert placement_count(one_shelves) == 6
      assert placement_count(many_shelves) == 6

      assert many_q == one_q,
             "N+1 across shelves: 6 shelves cost #{many_q} queries where 1 cost #{one_q}"
    end

    test "query count stays within a fixed bound regardless of fixture size" do
      big = seed_bookshelf(placements: 40, shelves: 4)

      {shelves, queries} =
        with_query_count(fn -> Shelving.get_bookshelf_shelves(big.user_id, "library") end)

      assert placement_count(shelves) == 40

      assert queries <= 8,
             "expected <= 8 queries for the shelf browse read path, got #{queries}"
    end

    test "every association the serializer touches is preloaded (no lazy fetch)" do
      fixture = seed_bookshelf(placements: 3, shelves: 1)

      shelves = Shelving.get_bookshelf_shelves(fixture.user_id, "library")

      {_result, queries} =
        with_query_count(fn ->
          for shelf <- shelves, placement <- shelf.placements do
            _ = placement.book.title
            _ = placement.book.author.name
            _ = Enum.map(placement.book.editions, & &1.isbn)
            _ = placement.bookshelf.user.id
          end
        end)

      assert queries == 0,
             "serializing the preloaded graph fired #{queries} lazy queries — an N+1 in disguise"
    end
  end

  defp explain_without_seqscan(query) do
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_bitmapscan = off")

    plan = SQL.explain(Repo, :all, query)

    Repo.query!("SET LOCAL enable_seqscan = on")
    Repo.query!("SET LOCAL enable_bitmapscan = on")

    plan
  end

  defp seed_bookshelf(placements: placement_count, shelves: shelf_count) do
    user = insert(:user)
    bookshelf = insert(:bookshelf, user: user, name: "library")

    shelves =
      for position <- 0..(shelf_count - 1) do
        insert(:shelf, bookshelf: bookshelf, position: position)
      end

    for i <- 1..placement_count do
      shelf = Enum.at(shelves, rem(i, shelf_count))
      book = insert(:book, author: insert(:author))
      insert(:book_edition, book: book)

      insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book, position: i)
    end

    %{user_id: user.id, bookshelf: bookshelf}
  end

  defp placement_count(shelves) do
    shelves |> Enum.flat_map(& &1.placements) |> length()
  end

  defp with_query_count(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {:shelving_qcount, ref}

    :telemetry.attach(
      handler_id,
      [:core, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, {ref, :query})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_query_count(ref, 0)}
  end

  defp drain_query_count(ref, acc) do
    receive do
      {^ref, :query} -> drain_query_count(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
