defmodule Stacks.UploadCacheTest do
  @moduledoc """
    Suite 8: Cache tests for upload pipeline.

    Covers BookDetailCache invalidation in upload context and
    BudgetTracker budget enforcement for vision API calls.
  """

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

    :sys.replace_state(BudgetTracker, fn _old ->
      %Stacks.AI.BudgetTracker{providers: %{}, daily_total_cents: 0, monthly_total_cents: 0}
    end)

    :ok
  end

  describe "BookDetailCache invalidation via CacheInvalidationHandler" do
    @tag stories: ["US-1.1.1"], suite: :cache
    test "book.created event invalidates a cached entry" do
      book_id = Ecto.UUID.generate()

      BookDetailCache.put(book_id, %{title: "Stale Entry"})
      assert {:ok, _} = BookDetailCache.get(book_id)

      event = %{event_type: "book.created", aggregate_id: book_id, payload: %{}}
      assert :ok = CacheInvalidationHandler.handle_event(event)

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

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)

      BookDetailCache.put(book_id, %{title: "The Song of Achilles"})

      assert {:ok, %{title: "The Song of Achilles"}} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "cache entry structure stores data with monotonic timestamp" do
      book_id = Ecto.UUID.generate()
      data = %{title: "Test", author: "Author"}

      BookDetailCache.put(book_id, data)

      [{^book_id, ^data, inserted_at}] = :ets.lookup(:book_detail_cache, book_id)
      assert is_integer(inserted_at)
      assert_in_delta inserted_at, System.monotonic_time(:millisecond), 1_000
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "TTL expiry: entries older than 5 minutes return :miss" do
      book_id = Ecto.UUID.generate()
      expired_at = System.monotonic_time(:millisecond) - 360_000
      :ets.insert(:book_detail_cache, {book_id, %{title: "Old"}, expired_at})

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "entries within TTL window are still returned" do
      book_id = Ecto.UUID.generate()
      recent_at = System.monotonic_time(:millisecond) - 240_000
      :ets.insert(:book_detail_cache, {book_id, %{title: "Recent"}, recent_at})

      assert {:ok, %{title: "Recent"}} = BookDetailCache.get(book_id)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "book.created for each book in multi-book resolution invalidates each cache entry" do
      book_id_1 = Ecto.UUID.generate()
      book_id_2 = Ecto.UUID.generate()

      BookDetailCache.put(book_id_1, %{title: "The Left Hand of Darkness"})
      BookDetailCache.put(book_id_2, %{title: "The Dispossessed"})
      assert {:ok, _} = BookDetailCache.get(book_id_1)
      assert {:ok, _} = BookDetailCache.get(book_id_2)

      event_1 = %{event_type: "book.created", aggregate_id: book_id_1, payload: %{}}
      event_2 = %{event_type: "book.created", aggregate_id: book_id_2, payload: %{}}
      assert :ok = CacheInvalidationHandler.handle_event(event_1)
      assert :ok = CacheInvalidationHandler.handle_event(event_2)

      assert {:miss, ^book_id_1} = BookDetailCache.get(book_id_1)
      assert {:miss, ^book_id_2} = BookDetailCache.get(book_id_2)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "invalidate_all/0 clears all cached entries" do
      ids = for _ <- 1..3, do: Ecto.UUID.generate()
      Enum.each(ids, &BookDetailCache.put(&1, %{title: "Book #{&1}"}))

      Enum.each(ids, fn id -> assert {:ok, _} = BookDetailCache.get(id) end)

      BookDetailCache.invalidate_all()

      Enum.each(ids, fn id -> assert {:miss, ^id} = BookDetailCache.get(id) end)
    end
  end

  describe "BookDetailCache poisoning prevention on upload failure" do
    @tag stories: ["US-1.1.1"], suite: :cache, security: true
    test "store_upload failure does not insert any entry into the cache" do
      assert :ets.info(:book_detail_cache, :size) == 0

      user = insert(:user)

      bogus_path = "/tmp/nonexistent_#{System.unique_integer([:positive])}.jpg"
      upload = %Plug.Upload{path: bogus_path, filename: "x.jpg", content_type: "image/jpeg"}

      assert {:error, _reason} = Uploads.store_upload(user.id, upload)

      assert :ets.info(:book_detail_cache, :size) == 0
    end

    @tag stories: ["US-1.1.1"], suite: :cache, security: true
    test "storage backend failure does not insert any entry into the cache" do
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

  describe "BookDetailCache age-gated segregation" do
    @tag stories: ["US-1.1.4"], suite: :cache, security: true
    test "age-gated book cached after age-verified fetch is still gated for non-verified viewer" do
      {:ok, gated_book} =
        Books.create(%{
          "title" => "Gated Title",
          "isbn" => "9780316769488",
          "visibility_tier" => "age_gated"
        })

      BookDetailCache.put(gated_book.id, gated_book)

      assert {:ok, cached} = BookDetailCache.get(gated_book.id)
      assert cached.visibility_tier == "age_gated"
    end

    @tag stories: ["US-1.1.4"], suite: :cache, security: true
    test "raising the age gate on an already-cached book gates the very next read" do
      {:ok, book} =
        Books.create(%{
          "title" => "Age Gated Cached",
          "isbn" => "9780140449136",
          "visibility_tier" => "public"
        })

      assert %{visibility_tier: "public"} = read_as_controller(book.id)
      assert {:ok, %{visibility_tier: "public"}} = BookDetailCache.get(book.id)

      assert {:ok, %{visibility_tier: "age_gated"}} =
               Books.set_visibility_tier(book.id, "age_gated", source: :user)

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

  describe "BudgetTracker budget enforcement" do
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

      state = BudgetTracker.current_state()
      assert state.daily_total_cents == 300
      assert state.providers["modal"] == 300
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "record_cost/2 with zero cost is a no-op on totals" do
      BudgetTracker.record_cost(:modal, 0)
      state = BudgetTracker.current_state()
      assert state.daily_total_cents == 0
      assert state.monthly_total_cents == 0
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "check_budget/1 returns :ok when under daily limit" do
      BudgetTracker.record_cost(:modal, 100)
      _ = BudgetTracker.current_state()

      assert :ok = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "check_budget/1 returns {:error, :daily_limit_exceeded} when at daily limit" do
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
      :sys.replace_state(BudgetTracker, fn state ->
        %{state | monthly_total_cents: 5000, daily_total_cents: 0}
      end)

      assert {:error, :monthly_limit_exceeded} = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "daily reset clears daily total and providers but preserves monthly total" do
      BudgetTracker.record_cost(:modal, 200)
      _ = BudgetTracker.current_state()

      send(Process.whereis(BudgetTracker), :reset_daily)

      state = BudgetTracker.current_state()
      assert state.daily_total_cents == 0
      assert state.providers == %{}
      assert state.monthly_total_cents == 200
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "after daily reset, check_budget returns :ok even if previous day was full" do
      BudgetTracker.record_cost(:modal, 500)
      _ = BudgetTracker.current_state()
      assert {:error, :daily_limit_exceeded} = BudgetTracker.check_budget(:modal)

      send(Process.whereis(BudgetTracker), :reset_daily)
      _ = BudgetTracker.current_state()

      assert :ok = BudgetTracker.check_budget(:modal)
    end

    @tag stories: ["US-1.1.1"], suite: :cache
    test "monthly limit enforced even after daily reset" do
      BudgetTracker.record_cost(:modal, 4900)
      _ = BudgetTracker.current_state()

      send(Process.whereis(BudgetTracker), :reset_daily)
      _ = BudgetTracker.current_state()

      BudgetTracker.record_cost(:modal, 200)
      _ = BudgetTracker.current_state()

      assert {:error, :monthly_limit_exceeded} = BudgetTracker.check_budget(:modal)
    end
  end
end
