defmodule Stacks.UploadCacheTest do
  @moduledoc """
  Suite 8 (Issue #111): Cache tests for upload pipeline.

  Covers BookDetailCache invalidation in upload context and
  BudgetTracker budget enforcement for vision API calls.
  """

  # async: false because BudgetTracker is a global GenServer.
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.AI.BudgetTracker
  alias Stacks.Books
  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.Handlers.CacheInvalidationHandler
  alias Stacks.Uploads
  alias StacksWeb.Plugs.AgeGate

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
    test "book.created for each book in multi-book resolution invalidates each cache entry" do
      book_id_1 = Ecto.UUID.generate()
      book_id_2 = Ecto.UUID.generate()

      # Prime the cache for both books.
      BookDetailCache.put(book_id_1, %{title: "The Left Hand of Darkness"})
      BookDetailCache.put(book_id_2, %{title: "The Dispossessed"})
      assert {:ok, _} = BookDetailCache.get(book_id_1)
      assert {:ok, _} = BookDetailCache.get(book_id_2)

      # Dispatch a book.created event for each book individually.
      event_1 = %{event_type: "book.created", aggregate_id: book_id_1, payload: %{}}
      event_2 = %{event_type: "book.created", aggregate_id: book_id_2, payload: %{}}
      assert :ok = CacheInvalidationHandler.handle_event(event_1)
      assert :ok = CacheInvalidationHandler.handle_event(event_2)

      # Both cache entries should now be invalidated.
      assert {:miss, ^book_id_1} = BookDetailCache.get(book_id_1)
      assert {:miss, ^book_id_2} = BookDetailCache.get(book_id_2)
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
  # SECURITY — cache poisoning prevention (US-1.1.1)
  # ---------------------------------------------------------------------------

  describe "BookDetailCache poisoning prevention on upload failure" do
    @tag stories: ["US-1.1.1"], suite: :cache, security: true
    test "store_upload failure does not insert any entry into the cache" do
      # Snapshot the cache before — it's clean per the outer setup.
      assert :ets.info(:book_detail_cache, :size) == 0

      user = insert(:user)

      # Simulate an upload failure: File.read fails because the file does
      # not exist. store_upload returns {:error, _} without ever creating
      # an UploadedImage row, a Book row, or a BookEdition.
      bogus_path = "/tmp/nonexistent_#{System.unique_integer([:positive])}.jpg"
      upload = %Plug.Upload{path: bogus_path, filename: "x.jpg", content_type: "image/jpeg"}

      assert {:error, _reason} = Uploads.store_upload(user.id, upload)

      # No cache entry was inserted as a side-effect of the failed upload.
      # This protects against the upload path inadvertently writing
      # placeholder/empty data into BookDetailCache, which would surface
      # later as a stale 404 or empty book detail to other users.
      assert :ets.info(:book_detail_cache, :size) == 0
    end

    @tag stories: ["US-1.1.1"], suite: :cache, security: true
    test "storage backend failure does not insert any entry into the cache" do
      # Same property under a different mid-flow failure: the storage
      # backend rejects the upload. Uploads.store_upload short-circuits on
      # the {:error, :unavailable} from the backend before any DB or
      # cache write would happen.
      defmodule __MODULE__.FailingStorage do
        @behaviour Stacks.Storage.StorageBehaviour
        @impl true
        def put(_key, _data, _opts), do: {:error, :unavailable}
        @impl true
        def presigned_url(_key, _ttl \\ 900), do: {:error, :unavailable}
        @impl true
        def delete(_key), do: :ok
      end

      original = Application.get_env(:core, :storage)
      Application.put_env(:core, :storage, __MODULE__.FailingStorage)
      on_exit(fn -> Application.put_env(:core, :storage, original) end)

      assert :ets.info(:book_detail_cache, :size) == 0

      user = insert(:user)

      tmp_path =
        Path.join(System.tmp_dir!(), "poison_test_#{System.unique_integer([:positive])}.jpg")

      File.write!(tmp_path, "fake jpeg")
      on_exit(fn -> File.rm(tmp_path) end)

      upload = %Plug.Upload{path: tmp_path, filename: "x.jpg", content_type: "image/jpeg"}

      assert {:error, :unavailable} = Uploads.store_upload(user.id, upload)

      assert :ets.info(:book_detail_cache, :size) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # SECURITY — age-gated cache segregation (US-1.1.4)
  # ---------------------------------------------------------------------------

  describe "BookDetailCache age-gated segregation" do
    @tag stories: ["US-1.1.4"], suite: :cache, security: true
    test "age-gated book cached after age-verified fetch is still gated for non-verified viewer" do
      # The BookDetailCache key is the book_id alone — there is no
      # per-user or per-age-verification segregation in the cache itself.
      # This is intentional: age-gating is enforced per-request by the
      # AgeGate plug AFTER the cache lookup, so even when an age-verified
      # user populates the cache, a subsequent request from a
      # non-verified user must still be blocked.
      #
      # We test the controller-equivalent property: the cached entry
      # carries the book's `visibility_tier` field, which AgeGate checks
      # on every request. Cache hit alone does not bypass the gate.
      {:ok, gated_book} =
        Books.create(%{
          "title" => "Gated Title",
          "isbn" => "9780316769488",
          "visibility_tier" => "age_gated"
        })

      # Simulate an age-verified user populating the cache.
      BookDetailCache.put(gated_book.id, gated_book)

      # The cached value retains the visibility_tier flag, so AgeGate.enforce
      # can reject non-verified viewers without consulting the DB — as long as
      # the flag in the cache is the CURRENT one, which is the property the next
      # test exists to hold. If the cache stripped this field, segregation would
      # break here; if a tier change failed to evict, it would break there.
      assert {:ok, cached} = BookDetailCache.get(gated_book.id)
      assert cached.visibility_tier == "age_gated"
    end

    @tag stories: ["US-1.1.4"], suite: :cache, security: true
    test "raising the age gate on an already-cached book gates the very next read" do
      # ⚠️ What this test used to do: pre-seed the cache with the book ALREADY
      # `age_gated`, then assert `AgeGate.enforce` halted. The cached copy and the
      # database agreed, so nothing about caching was exercised — it could only
      # fail if the plug itself were broken — and it drew the wrong conclusion
      # from passing: "cache key isolation is therefore NOT required as long as
      # enforcement is per-request". Enforcement IS per-request. The value it
      # enforces against is not: `BookController.show/2` gates the book returned
      # by `cached_or_fetch/1`, so a cached PUBLIC copy was served ungated for the
      # full 5-minute TTL after the gate was raised (#357).
      #
      # The defect needs all three steps in this order: read (which caches the
      # public copy), raise the gate, read again. Raising into a COLD cache passes
      # however the invalidation is wired, or whether it is wired at all.
      {:ok, book} =
        Books.create(%{
          "title" => "Age Gated Cached",
          "isbn" => "9780140449136",
          "visibility_tier" => "public"
        })

      # 1. A reader looks at the public book. This is what populates the cache.
      assert %{visibility_tier: "public"} = read_as_controller(book.id)
      assert {:ok, %{visibility_tier: "public"}} = BookDetailCache.get(book.id)

      # 2. Someone marks it adults-only. No Oban drain here, on purpose: the
      #    eviction is synchronous, because a safety control must not wait for a
      #    queue (Stacks.Books.set_visibility_tier/3).
      assert {:ok, %{visibility_tier: "age_gated"}} =
               Books.set_visibility_tier(book.id, "age_gated", source: :user)

      # 3. The next reader, running the sequence the controller runs: cache
      #    lookup, then the gate on whatever came back.
      non_verified = insert(:user, age_verified: false)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Guardian.Plug.put_current_resource(non_verified)
        |> AgeGate.enforce(read_as_controller(book.id))

      assert conn.halted,
             "the age gate did not halt a non-verified viewer on the read after it was raised — " <>
               "BookDetailCache is still serving the pre-gate copy"

      assert conn.status == 403
    end
  end

  # Mirrors `StacksWeb.BookController.cached_or_fetch/1` — cache first, database
  # on a miss, and the miss re-populates. Deliberately NOT a straight
  # `Books.get_book_detail/1`: reading past the cache is what makes a
  # cache-staleness test vacuous.
  defp read_as_controller(book_id) do
    case BookDetailCache.get(book_id) do
      {:ok, cached} ->
        cached

      {:miss, _} ->
        book = Books.get_book_detail(book_id)
        BookDetailCache.put(book_id, book)
        book
    end
  end

  # ---------------------------------------------------------------------------
  # BudgetTracker in upload context
  # ---------------------------------------------------------------------------

  describe "BudgetTracker budget enforcement" do
    # Reset the global BudgetTracker to a clean zero state before each test and
    # restore original state after, so these tests don't bleed into each other or
    # into other test modules that also use the singleton.
    setup do
      original = :sys.get_state(BudgetTracker)

      :sys.replace_state(BudgetTracker, fn state ->
        %{state | daily_total_cents: 0, monthly_total_cents: 0, providers: %{}}
      end)

      on_exit(fn ->
        :sys.replace_state(BudgetTracker, fn _ -> original end)
      end)

      :ok
    end

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
