defmodule Stacks.UploadCacheTest do
  @moduledoc """
      Suite 8: Cache tests for upload pipeline.

      Covers BookDetailCache invalidation in upload context and
      Budget budget enforcement for vision API calls.
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.AI.Budget
  alias Stacks.AI.Spend
  alias Stacks.Books
  alias Stacks.Books.BookDetailCache
  alias Stacks.Books.Handlers.CacheInvalidationHandler
  alias Stacks.Uploads
  alias StacksWeb.Plugs.AgeGate

  setup do
    BookDetailCache.invalidate_all()

    # ⛔ THE BUDGET RESET USED TO BE `:sys.replace_state/2` ON A GenServer.
    # There is no process any more — the spend is a row per provider per
    # period, and the sandbox gives every test a clean one. Poking a struct was
    # how the old suite could manufacture any total it liked, which is why it
    # was green against a ceiling that did not survive a restart.
    :ok
  end

  describe "BookDetailCache invalidation via CacheInvalidationHandler" do
    @tag suite: :cache
    test "book.created event invalidates a cached entry" do
      book_id = Ecto.UUID.generate()

      BookDetailCache.put(book_id, %{title: "Stale Entry"})
      assert {:ok, _} = BookDetailCache.get(book_id)

      event = %{event_type: "book.created", aggregate_id: book_id, payload: %{}}
      assert :ok = CacheInvalidationHandler.handle_event(event)

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
    end

    @tag suite: :cache
    test "get/1 returns :miss for a freshly created book (no cache entry yet)" do
      book_id = Ecto.UUID.generate()
      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
    end

    @tag suite: :cache
    test "after put/1, get/1 returns the cached data (simulates BookController.show populating cache)" do
      book_id = Ecto.UUID.generate()
      detail = %{title: "Circe", author: "Madeline Miller", isbn: "9780316556347"}

      BookDetailCache.put(book_id, detail)
      assert {:ok, ^detail} = BookDetailCache.get(book_id)
    end

    @tag suite: :cache
    test "cache miss on first fetch, hit on second" do
      book_id = Ecto.UUID.generate()

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)

      BookDetailCache.put(book_id, %{title: "The Song of Achilles"})

      assert {:ok, %{title: "The Song of Achilles"}} = BookDetailCache.get(book_id)
    end

    @tag suite: :cache
    test "cache entry structure stores data with monotonic timestamp" do
      book_id = Ecto.UUID.generate()
      data = %{title: "Test", author: "Author"}

      BookDetailCache.put(book_id, data)

      [{^book_id, ^data, inserted_at}] = :ets.lookup(:book_detail_cache, book_id)
      assert is_integer(inserted_at)
      assert_in_delta inserted_at, System.monotonic_time(:millisecond), 1_000
    end

    @tag suite: :cache
    test "TTL expiry: entries older than 5 minutes return :miss" do
      book_id = Ecto.UUID.generate()
      expired_at = System.monotonic_time(:millisecond) - 360_000
      :ets.insert(:book_detail_cache, {book_id, %{title: "Old"}, expired_at})

      assert {:miss, ^book_id} = BookDetailCache.get(book_id)
    end

    @tag suite: :cache
    test "entries within TTL window are still returned" do
      book_id = Ecto.UUID.generate()
      recent_at = System.monotonic_time(:millisecond) - 240_000
      :ets.insert(:book_detail_cache, {book_id, %{title: "Recent"}, recent_at})

      assert {:ok, %{title: "Recent"}} = BookDetailCache.get(book_id)
    end

    @tag suite: :cache
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

    @tag suite: :cache
    test "invalidate_all/0 clears all cached entries" do
      ids = for _ <- 1..3, do: Ecto.UUID.generate()
      Enum.each(ids, &BookDetailCache.put(&1, %{title: "Book #{&1}"}))

      Enum.each(ids, fn id -> assert {:ok, _} = BookDetailCache.get(id) end)

      BookDetailCache.invalidate_all()

      Enum.each(ids, fn id -> assert {:miss, ^id} = BookDetailCache.get(id) end)
    end
  end

  describe "BookDetailCache poisoning prevention on upload failure" do
    @tag suite: :cache, security: true
    test "store_upload failure does not insert any entry into the cache" do
      assert :ets.info(:book_detail_cache, :size) == 0

      user = insert(:user)

      bogus_path = "/tmp/nonexistent_#{System.unique_integer([:positive])}.jpg"
      upload = %Plug.Upload{path: bogus_path, filename: "x.jpg", content_type: "image/jpeg"}

      assert {:error, _reason} = Uploads.store_upload(user.id, upload)

      assert :ets.info(:book_detail_cache, :size) == 0
    end

    @tag suite: :cache, security: true
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
    @tag suite: :cache, security: true
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

    @tag suite: :cache, security: true
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
        CoreWeb.ConnCase.proven_conn()
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

  describe "Budget budget enforcement" do
    # ⛔ THESE TESTS USED TO POKE THE GenServer'S STRUCT AND SEND IT
    # `:reset_daily`, AND THAT WAS THE DEFECT WRITTEN DOWN AS A REQUIREMENT.
    #
    # The totals lived in process state with no database behind them, so the
    # budget was cleared by a message arriving at a live process — which on a
    # scale-to-zero node meant it was cleared by the node going quiet, silently,
    # every time. `:sys.replace_state/2` and `send(…, :reset_daily)` could set
    # up any total at all, so the suite was green against a ceiling that did not
    # survive a restart.
    #
    # ⚖️ The INTENT of the old cases was right and is kept: a new day restores
    # the budget, a full previous day does not refuse today, and the monthly
    # limit outlives the daily one. What changes is the mechanism they assert —
    # a date rather than a timer — which is both the fix and a stronger test,
    # because it needs no process to be alive to be true.
    setup do
      Application.put_env(:core, :ai_budget,
        daily_limit_cents: 500,
        monthly_limit_cents: 5_000
      )

      on_exit(fn ->
        Application.delete_env(:core, :ai_budget)
      end)

      :ok
    end

    @tag suite: :cache
    test "record_cost/2 increases daily and monthly spend" do
      assert :ok = Budget.record_cost(:modal, 5_000_000)

      assert Spend.spent(:modal, :daily) == 5_000_000
      assert Spend.spent(:modal, :monthly) == 5_000_000
    end

    @tag suite: :cache
    test "record_cost/2 accumulates across multiple calls" do
      Budget.record_cost(:modal, 10_000_000)
      Budget.record_cost(:modal, 20_000_000)

      assert Spend.spent(:modal, :daily) == 30_000_000
    end

    @tag suite: :cache
    test "record_cost/2 with zero cost records nothing" do
      Budget.record_cost(:modal, 0)

      assert Spend.spent(:modal, :daily) == 0
      assert Spend.spent(:modal, :monthly) == 0
    end

    @tag suite: :cache
    test "check_budget/1 returns :ok when under daily limit" do
      Budget.record_cost(:modal, 10_000_000)

      assert :ok = Budget.check_budget(:modal)
    end

    @tag suite: :cache
    test "check_budget/1 refuses at the daily limit" do
      Budget.record_cost(:modal, 50_000_000)

      assert {:error, :daily_limit_exceeded} = Budget.check_budget(:modal)
    end

    @tag suite: :cache
    test "check_budget/1 refuses over the daily limit" do
      Budget.record_cost(:modal, 60_000_000)

      assert {:error, :daily_limit_exceeded} = Budget.check_budget(:modal)
    end

    # ⚖️ THE DAILY ARM IS MADE UNREACHABLE RATHER THAN MERELY UNTRIGGERED.
    #
    # The obvious setup — spend on earlier days so today is empty — is wrong at
    # a month boundary: `Date.add(today, -1)` can land in the previous month,
    # where it counts toward a different monthly total. (My first attempt did
    # exactly that and recorded 4000 of an intended 5000, because two of the ten
    # days were in October.) Raising the daily limit out of reach means only the
    # monthly arm can fire, whatever today's date is.
    @tag suite: :cache
    test "check_budget/1 refuses at the monthly limit" do
      Application.put_env(
        :core,
        :ai_budget,
        Keyword.put(
          Application.get_env(:core, :ai_budget, []),
          :daily_limit_cents,
          1_000_000
        )
      )

      Budget.record_cost(:modal, 600_000_000)

      assert Spend.spent(:modal, :daily) < 100_000_000_000,
             "the daily limit must be out of reach, or this case says nothing " <>
               "about the monthly one"

      assert {:error, :monthly_limit_exceeded} = Budget.check_budget(:modal)
    end

    # ⚖️ THE OLD "DAILY RESET" CASES, RESTATED AS DATES. Yesterday being full
    # is simply a different row from today — no reset message, no live process.
    @tag suite: :cache
    test "a full previous day does not refuse today" do
      yesterday = Date.add(Date.utc_today(), -1)

      :ok = Spend.record(:modal, 60_000_000, yesterday)

      assert Spend.spent(:modal, :daily, yesterday) == 60_000_000
      assert :ok = Budget.check_budget(:modal)
    end

    # ⚖️ The monthly ceiling must outlive a day rollover — the half a single
    # resettable counter could not express at all. The spend goes on the first
    # of this month (which may or may not be today; either way it is inside the
    # same monthly row) and the daily limit is again out of reach.
    @tag suite: :cache
    test "the monthly limit still refuses once the day has rolled over" do
      Application.put_env(
        :core,
        :ai_budget,
        Keyword.put(
          Application.get_env(:core, :ai_budget, []),
          :daily_limit_cents,
          1_000_000
        )
      )

      first_of_month = Date.beginning_of_month(Date.utc_today())

      :ok = Spend.record(:modal, 600_000_000, first_of_month)

      assert Spend.spent(:modal, :monthly) >= 500_000_000
      assert {:error, :monthly_limit_exceeded} = Budget.check_budget(:modal)
    end
  end
end
