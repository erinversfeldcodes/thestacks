defmodule Stacks.UploadCacheTest do
  @moduledoc """
  Suite 8 (Issue #111): Cache tests for upload pipeline.

  Covers BookDetailCache invalidation in upload context and
  BudgetTracker budget enforcement for vision API calls.
  """

  # async: false because BudgetTracker is a global GenServer.
  use Core.DataCase, async: false

  alias Stacks.AI.BudgetTracker
  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.Handlers.CacheInvalidationHandler

  setup do
    BookDetailCache.invalidate_all()

    # Full reset of BudgetTracker state (daily + monthly + providers).
    :sys.replace_state(BudgetTracker, fn _old ->
      %Stacks.AI.BudgetTracker{providers: %{}, daily_total_cents: 0, monthly_total_cents: 0}
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # BookDetailCache in upload context
  # ---------------------------------------------------------------------------

  describe "BookDetailCache invalidation via CacheInvalidationHandler" do
    @tag stories: ["US-1.1.1"], suite: :cache
    test "book.created event invalidates a cached entry" do
      book_id = Ecto.UUID.generate()

      # Simulate a cached entry that existed before the book was created
      # (e.g., a stale 404-placeholder or pre-existing detail).
      BookDetailCache.put(book_id, %{title: "Stale Entry"})
      assert {:ok, _} = BookDetailCache.get(book_id)

      # The CacheInvalidationHandler fires on book.created events.
      event = %{event_type: "book.created", aggregate_id: book_id, payload: %{}}
      assert :ok = CacheInvalidationHandler.handle_event(event)

      # Cache should now be empty for this book.
      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "get/1 returns :miss for a freshly created book (no cache entry yet)" do
      book_id = Ecto.UUID.generate()
      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "after put/1, get/1 returns the cached data (simulates BookController.show populating cache)" do
      book_id = Ecto.UUID.generate()
      detail = %{title: "Circe", author: "Madeline Miller", isbn: "9780316556347"}

      BookDetailCache.put(book_id, detail)
      assert {:ok, ^detail} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "cache miss on first fetch, hit on second" do
      book_id = Ecto.UUID.generate()

      # First fetch: miss
      assert {:miss, ^book_id} = BookDetailCache.get(book_id)

      # Populate cache (as BookController.show would)
      BookDetailCache.put(book_id, %{title: "The Song of Achilles"})

      # Second fetch: hit
      assert {:ok, %{title: "The Song of Achilles"}} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "cache entry structure stores data with monotonic timestamp" do
      book_id = Ecto.UUID.generate()
      data = %{title: "Test", author: "Author"}

      BookDetailCache.put(book_id, data)

      # Verify the ETS entry has the expected 3-element tuple structure:
      # {book_id, data, inserted_at_monotonic}
      [{^book_id, ^data, inserted_at}] = :ets.lookup(:book_detail_cache, book_id)
      assert is_integer(inserted_at)
      assert_in_delta inserted_at, System.monotonic_time(:millisecond), 1_000
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "TTL expiry: entries older than 5 minutes return :miss" do
      book_id = Ecto.UUID.generate()
      # Insert an entry with an expired timestamp (6 minutes ago).
      expired_at = System.monotonic_time(:millisecond) - 360_000
      :ets.insert(:book_detail_cache, {book_id, %{title: "Old"}, expired_at})

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "entries within TTL window are still returned" do
      book_id = Ecto.UUID.generate()
      # Insert an entry from 4 minutes ago (within 5 min TTL).
      recent_at = System.monotonic_time(:millisecond) - 240_000
      :ets.insert(:book_detail_cache, {book_id, %{title: "Recent"}, recent_at})

      assert {:ok, %{title: "Recent"}} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "invalidate_all/0 clears all cached entries" do
      ids = for _ <- 1..3, do: Ecto.UUID.generate()
      Enum.each(ids, &BookDetailCache.put(&1, %{title: "Book #{&1}"}))

      # All populated
      Enum.each(ids, fn id -> assert {:ok, _} = BookDetailCache.get(id) end)

      BookDetailCache.invalidate_all()

      # All cleared
      Enum.each(ids, fn id -> assert {:miss, ^id} = BookDetailCache.get(id) end)
    end
  end

  # ---------------------------------------------------------------------------
  # BudgetTracker in upload context
  # ---------------------------------------------------------------------------

  describe "BudgetTracker budget enforcement" do
    @tag stories: ["US-1.1.1"], suite: :cache
    test "record_cost/2 increases daily spend" do
      assert :ok = BudgetTracker.record_cost(:modal, 50)

      state = BudgetTracker.current_state()
      assert state.daily_total_cents == 50
      assert state.monthly_total_cents == 50
      assert state.providers["modal"] == 50
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "record_cost/2 accumulates across multiple calls" do
      BudgetTracker.record_cost(:modal, 100)
      BudgetTracker.record_cost(:modal, 200)

      # Allow casts to be processed
      state = BudgetTracker.current_state()
      assert state.daily_total_cents == 300
      assert state.providers["modal"] == 300
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "record_cost/2 with zero cost is a no-op on totals" do
      BudgetTracker.record_cost(:modal, 0)
      # current_state/0 is a call — it serializes after the cast, ensuring the
      # GenServer has processed the record_cost cast before we read state.
      state = BudgetTracker.current_state()
      assert state.daily_total_cents == 0
      assert state.monthly_total_cents == 0
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "check_budget/1 returns :ok when under daily limit" do
      BudgetTracker.record_cost(:modal, 100)
      # current_state/0 is a call that serializes after preceding casts.
      _ = BudgetTracker.current_state()

      assert :ok = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "check_budget/1 returns {:error, :daily_limit_exceeded} when at daily limit" do
      # Default daily limit is 500 cents
      BudgetTracker.record_cost(:modal, 500)
      _ = BudgetTracker.current_state()

      assert {:error, :daily_limit_exceeded} = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "check_budget/1 returns {:error, :daily_limit_exceeded} when over daily limit" do
      BudgetTracker.record_cost(:modal, 600)
      _ = BudgetTracker.current_state()

      assert {:error, :daily_limit_exceeded} = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "check_budget/1 returns {:error, :monthly_limit_exceeded} when over monthly limit" do
      # Isolate monthly from daily: set monthly >= 5000 but daily = 0 via state replacement.
      :sys.replace_state(BudgetTracker, fn state ->
        %{state | monthly_total_cents: 5000, daily_total_cents: 0}
      end)

      assert {:error, :monthly_limit_exceeded} = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "daily reset clears daily total and providers but preserves monthly total" do
      BudgetTracker.record_cost(:modal, 200)
      _ = BudgetTracker.current_state()

      # Simulate midnight reset
      send(Process.whereis(BudgetTracker), :reset_daily)

      state = BudgetTracker.current_state()
      assert state.daily_total_cents == 0
      assert state.providers == %{}
      # Monthly total persists across daily resets.
      assert state.monthly_total_cents == 200
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "after daily reset, check_budget returns :ok even if previous day was full" do
      BudgetTracker.record_cost(:modal, 500)
      _ = BudgetTracker.current_state()
      assert {:error, :daily_limit_exceeded} = BudgetTracker.check_budget(:modal)

      # Simulate midnight reset
      send(Process.whereis(BudgetTracker), :reset_daily)
      _ = BudgetTracker.current_state()

      assert :ok = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "monthly limit enforced even after daily reset" do
      # Fill up almost all monthly budget
      BudgetTracker.record_cost(:modal, 4900)
      _ = BudgetTracker.current_state()

      # Reset daily
      send(Process.whereis(BudgetTracker), :reset_daily)
      _ = BudgetTracker.current_state()

      # Add more cost to exceed monthly
      BudgetTracker.record_cost(:modal, 200)
      _ = BudgetTracker.current_state()

      # Monthly total is now 5100, daily is 200
      assert {:error, :monthly_limit_exceeded} = BudgetTracker.check_budget(:modal)
    end
  end
end
