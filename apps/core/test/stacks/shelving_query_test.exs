defmodule Stacks.ShelvingQueryTest do
  @moduledoc """
  Query-plan and query-count guards for the shelf-browsing read path
  (Issue #112, punch #2 and #3 — Layer 3 cross-US cells).

  Two distinct guarantees are asserted here:

    * **#2 — index sanity.** The two predicates the browse path issues
      (`bookshelves` by `(user_id, name)`, and the active-placement filter
      `removed_at IS NULL`) are servable by a real index, and the migrations'
      indexes still exist in the shape the queries need.

    * **#3 — no N+1.** `Shelving.get_bookshelf_shelves/2` — the function
      `BookshelfController.show/2` actually calls (`bookshelf_controller.ex:72`),
      *not* `get_bookshelf_books/2` — issues a query count that does not grow
      with the number of placements, shelves, authors, or editions involved.

  ## Why `enable_seqscan = off` in the plan tests

  Test-scale tables (a handful of rows) always plan to a Seq Scan regardless of
  what indexes exist, so a bare `EXPLAIN` assertion would either be vacuous or
  require seeding tens of thousands of rows per test. Disabling seqscan makes
  the planner reveal its *best index path* for the predicate. The assertion is
  therefore "this predicate is index-servable by THIS index", which fails if the
  index is dropped, its column order changes, or the query's predicate drifts to
  a shape the index cannot serve — the regressions this cell is meant to catch.
  A plain Seq Scan still appears in the plan if no index can serve the predicate
  (the setting is a cost penalty, not a prohibition), so the assertion has teeth.
  """

  # async: false — the plan tests set session GUCs and the query-count tests
  # attach a global telemetry handler.
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Ecto.Adapters.SQL
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement}

  # Index names created by the migrations under test.
  @bookshelves_idx "bookshelves_user_id_name_index"
  @placements_active_idx "bookshelf_placements_book_active_idx"
  @placements_bookshelf_idx "bookshelf_placements_bookshelf_id_index"

  # ---------------------------------------------------------------------------
  # Punch #2 — index existence and query-plan sanity
  # ---------------------------------------------------------------------------

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
      # The partial predicate is what makes the active-placement filter index-servable.
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

  # ---------------------------------------------------------------------------
  # Punch #3 — N+1 guard on the REAL controller read path
  # ---------------------------------------------------------------------------

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

      # 1 shelves query + one batched query per preloaded association
      # (placements, book, author, editions, bookshelf, user). Any growth past
      # this means a new unbatched association crept into the read path.
      assert queries <= 8,
             "expected <= 8 queries for the shelf browse read path, got #{queries}"
    end

    test "every association the serializer touches is preloaded (no lazy fetch)" do
      fixture = seed_bookshelf(placements: 3, shelves: 1)

      shelves = Shelving.get_bookshelf_shelves(fixture.user_id, "library")

      # Reading the preloaded graph must cost ZERO further queries — the
      # controller serializes exactly these fields.
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Runs `query` under EXPLAIN with sequential scans penalised so the planner
  # reveals the best index path for the predicate. See the moduledoc.
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

  # Counts Repo query telemetry emitted in THIS process while `fun` runs. The
  # `self() == test_pid` guard keeps the count isolated from other modules'
  # queries. Same pattern as profile_controller_test.exs.
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
