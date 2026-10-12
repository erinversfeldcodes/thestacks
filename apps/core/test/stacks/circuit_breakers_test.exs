defmodule Stacks.CircuitBreakersTest do
  @moduledoc """
      Tests that all circuit breakers are installed at startup and behave correctly
      when circuits blow via real failure paths.

      Tests are async: false because they share global fuse state. Each test
      resets fuses in setup/teardown to ensure isolation.

      ## Fuse semantics

      `{:standard, N, T}` blows when the melt count exceeds N within window T,
      i.e., after N+1 melts. All test fuses use threshold=2 so 3 failures blow
      the circuit — keeping test loops short without hitting the production threshold.
  """

  use ExUnit.Case, async: false

  alias Stacks.AI.Client, as: AIClient
  alias Stacks.AI.TogetherClient
  alias Stacks.Books.ISBNResolver
  alias Stacks.CircuitBreakers
  alias Stacks.Enrichment.ScraperClient
  alias Stacks.Testing.FailingHttpClient

  defp with_telemetry_capture(event_names, fun) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      "test-#{inspect(ref)}",
      event_names,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach("test-#{inspect(ref)}")
    end

    collect_telemetry()
  end

  defp collect_telemetry do
    receive do
      {:telemetry, event, measurements, metadata} ->
        [{event, measurements, metadata} | collect_telemetry()]
    after
      0 -> []
    end
  end

  defp install_test_fuse(name, threshold, window_ms) do
    remove_fuse(name)
    :fuse.install(name, {{:standard, threshold, window_ms}, {:reset, 60_000}})
  end

  defp remove_fuse(name) do
    :fuse.remove(name)
  catch
    _, _ -> :ok
  end

  describe "Stacks.CircuitBreakers.store_fuse/1 — per-store isolation" do
    test "one failing store does not open the circuit for another" do
      bad = CircuitBreakers.store_fuse("za/hostile_shop")
      good = CircuitBreakers.store_fuse("za/fine_shop")

      refute bad == good, "each store must get its own circuit"

      Enum.each(1..5, fn _ -> CircuitBreakers.melt(bad) end)

      assert :fuse.ask(bad, :sync) == :blown
      assert :fuse.ask(good, :sync) == :ok, "a healthy store must stay scrapeable"

      assert :fuse.ask(:scraper_fuse, :sync) == :ok,
             "a store-specific fault must not open the service-wide circuit"
    end

    test "the same store name always resolves to the same fuse" do
      assert CircuitBreakers.store_fuse("za/exclusive_books") ==
               CircuitBreakers.store_fuse("za/exclusive_books")
    end

    test "store identifiers are normalised into readable fuse names" do
      assert CircuitBreakers.store_fuse("za/exclusive_books") ==
               :scraper_store_fuse_za_exclusive_books
    end

    test "falls back to the shared fuse when no store is named" do
      assert CircuitBreakers.store_fuse(nil) == :scraper_fuse
    end
  end

  describe "Stacks.CircuitBreakers — startup installation" do
    setup do
      for name <- [
            :vision_fuse,
            :together_ai_fuse,
            :open_library_fuse,
            :google_books_fuse,
            :scraper_fuse
          ] do
        remove_fuse(name)
      end

      on_exit(fn ->
        for name <- [
              :vision_fuse,
              :together_ai_fuse,
              :open_library_fuse,
              :google_books_fuse,
              :scraper_fuse
            ] do
          remove_fuse(name)
        end

        CircuitBreakers.install_all()
      end)
    end

    test "install_all/0 installs :vision_fuse" do
      assert {:error, :not_found} = :fuse.ask(:vision_fuse, :sync)
      CircuitBreakers.install_all()
      assert :ok = :fuse.ask(:vision_fuse, :sync)
    end

    test "install_all/0 installs :together_ai_fuse" do
      assert {:error, :not_found} = :fuse.ask(:together_ai_fuse, :sync)
      CircuitBreakers.install_all()
      assert :ok = :fuse.ask(:together_ai_fuse, :sync)
    end

    test "install_all/0 installs :open_library_fuse" do
      assert {:error, :not_found} = :fuse.ask(:open_library_fuse, :sync)
      CircuitBreakers.install_all()
      assert :ok = :fuse.ask(:open_library_fuse, :sync)
    end

    test "install_all/0 installs :google_books_fuse" do
      assert {:error, :not_found} = :fuse.ask(:google_books_fuse, :sync)
      CircuitBreakers.install_all()
      assert :ok = :fuse.ask(:google_books_fuse, :sync)
    end

    test "install_all/0 installs :scraper_fuse" do
      assert {:error, :not_found} = :fuse.ask(:scraper_fuse, :sync)
      CircuitBreakers.install_all()
      assert :ok = :fuse.ask(:scraper_fuse, :sync)
    end

    test "install_all/0 is idempotent — safe to call when fuses already installed" do
      CircuitBreakers.install_all()
      assert :ok = CircuitBreakers.install_all()
      assert :ok = :fuse.ask(:vision_fuse, :sync)
    end
  end

  describe "Stacks.CircuitBreakers.melt/1 — telemetry" do
    setup do
      install_test_fuse(:test_melt_fuse, 2, 10_000)
      on_exit(fn -> remove_fuse(:test_melt_fuse) end)
    end

    test "emits [:stacks, :fuse, :melt] when circuit is still closed" do
      events =
        with_telemetry_capture([[:stacks, :fuse, :melt], [:stacks, :fuse, :blown]], fn ->
          CircuitBreakers.melt(:test_melt_fuse)
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :melt] and meta.fuse_name == :test_melt_fuse
             end),
             "expected [:stacks, :fuse, :melt] telemetry, got: #{inspect(events)}"
    end

    test "emits [:stacks, :fuse, :blown] when threshold is exceeded" do
      CircuitBreakers.melt(:test_melt_fuse)
      CircuitBreakers.melt(:test_melt_fuse)

      events =
        with_telemetry_capture([[:stacks, :fuse, :melt], [:stacks, :fuse, :blown]], fn ->
          CircuitBreakers.melt(:test_melt_fuse)
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :test_melt_fuse
             end),
             "expected [:stacks, :fuse, :blown] telemetry, got: #{inspect(events)}"
    end
  end

  describe ":vision_fuse — AI.Client" do
    setup do
      install_test_fuse(:vision_fuse, 2, 10_000)
      original_url = Application.get_env(:core, :vision_service_url)
      original_client = Application.get_env(:core, :vision_client)

      Application.put_env(:core, :vision_service_url, "http://localhost:1")
      Application.put_env(:core, :vision_client, Stacks.AI.Client)

      on_exit(fn ->
        Application.put_env(:core, :vision_service_url, original_url)
        Application.put_env(:core, :vision_client, original_client)
        remove_fuse(:vision_fuse)
        CircuitBreakers.install_all()
      end)
    end

    test "fuse is installed and starts :ok" do
      assert :ok = :fuse.ask(:vision_fuse, :sync)
    end

    test "circuit blows after repeated connection failures and returns {:error, :circuit_open}" do
      for _ <- 1..3 do
        AIClient.call_vision("is_book", %{image_url: "https://example.com/cover.jpg"})
      end

      assert {:error, :circuit_open} =
               AIClient.call_vision("is_book", %{
                 image_url: "https://example.com/cover.jpg"
               })
    end

    test "[:stacks, :fuse, :blown] telemetry fires when :vision_fuse blows" do
      for _ <- 1..2 do
        AIClient.call_vision("is_book", %{image_url: "https://example.com/cover.jpg"})
      end

      events =
        with_telemetry_capture([[:stacks, :fuse, :blown]], fn ->
          AIClient.call_vision("is_book", %{image_url: "https://example.com/cover.jpg"})
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :vision_fuse
             end),
             "expected [:stacks, :fuse, :blown] for :vision_fuse, got: #{inspect(events)}"
    end
  end

  describe ":together_ai_fuse — AI.TogetherClient" do
    setup do
      install_test_fuse(:together_ai_fuse, 2, 10_000)
      original_client = Application.get_env(:core, :together_client)
      original_key = Application.get_env(:core, :vision_together_api_key)
      original_url = Application.get_env(:core, :together_ai_base_url)

      Application.put_env(:core, :together_client, Stacks.AI.TogetherClient)
      Application.put_env(:core, :vision_together_api_key, "test-key-unused")
      Application.put_env(:core, :together_ai_base_url, "http://localhost:1")

      on_exit(fn ->
        Application.put_env(:core, :together_client, original_client)
        Application.put_env(:core, :vision_together_api_key, original_key)
        Application.put_env(:core, :together_ai_base_url, original_url)
        remove_fuse(:together_ai_fuse)
        CircuitBreakers.install_all()
      end)
    end

    test "fuse is installed and starts :ok" do
      assert :ok = :fuse.ask(:together_ai_fuse, :sync)
    end

    test "circuit blows after repeated connection failures and returns {:error, :circuit_open}" do
      for _ <- 1..3 do
        TogetherClient.summarize_reviews("some review text", %{
          title: "Test",
          author: "Author"
        })
      end

      assert {:error, :circuit_open} =
               TogetherClient.summarize_reviews("text", %{title: "T", author: "A"})
    end

    test "[:stacks, :fuse, :blown] telemetry fires when :together_ai_fuse blows" do
      for _ <- 1..2 do
        TogetherClient.summarize_reviews("text", %{title: "T", author: "A"})
      end

      events =
        with_telemetry_capture([[:stacks, :fuse, :blown]], fn ->
          TogetherClient.summarize_reviews("text", %{title: "T", author: "A"})
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :together_ai_fuse
             end),
             "expected [:stacks, :fuse, :blown] for :together_ai_fuse, got: #{inspect(events)}"
    end
  end

  describe ":open_library_fuse — Books.ISBNResolver" do
    setup do
      install_test_fuse(:open_library_fuse, 2, 10_000)
      install_test_fuse(:google_books_fuse, 2, 10_000)
      original_client = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, FailingHttpClient)

      on_exit(fn ->
        Application.put_env(:core, :isbn_http_client, original_client)
        remove_fuse(:open_library_fuse)
        remove_fuse(:google_books_fuse)
        CircuitBreakers.install_all()
      end)
    end

    test "fuse is installed and starts :ok" do
      assert :ok = :fuse.ask(:open_library_fuse, :sync)
    end

    test "circuit blows after repeated Open Library failures" do
      for _ <- 1..3 do
        ISBNResolver.resolve("9780743273565")
      end

      assert :blown = :fuse.ask(:open_library_fuse, :sync)
    end

    test "[:stacks, :fuse, :blown] telemetry fires when :open_library_fuse blows" do
      for _ <- 1..2 do
        ISBNResolver.resolve("9780743273565")
      end

      events =
        with_telemetry_capture([[:stacks, :fuse, :blown]], fn ->
          ISBNResolver.resolve("9780743273565")
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :open_library_fuse
             end),
             "expected [:stacks, :fuse, :blown] for :open_library_fuse, got: #{inspect(events)}"
    end

    test "search_by_title failures also contribute to :open_library_fuse melt count" do
      :fuse.melt(:google_books_fuse)
      :fuse.melt(:google_books_fuse)
      :fuse.melt(:google_books_fuse)

      for _ <- 1..3 do
        ISBNResolver.search_by_title("Some Book", "Some Author")
      end

      assert :blown = :fuse.ask(:open_library_fuse, :sync)
    end
  end

  describe ":google_books_fuse — Books.ISBNResolver" do
    setup do
      install_test_fuse(:google_books_fuse, 2, 10_000)
      install_test_fuse(:open_library_fuse, 0, 10_000)
      :fuse.melt(:open_library_fuse)

      original_client = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, FailingHttpClient)

      on_exit(fn ->
        Application.put_env(:core, :isbn_http_client, original_client)
        remove_fuse(:google_books_fuse)
        remove_fuse(:open_library_fuse)
        CircuitBreakers.install_all()
      end)
    end

    test "fuse is installed and starts :ok" do
      assert :ok = :fuse.ask(:google_books_fuse, :sync)
    end

    test "circuit blows after repeated Google Books failures" do
      for _ <- 1..3 do
        ISBNResolver.resolve("9780743273565")
      end

      assert :blown = :fuse.ask(:google_books_fuse, :sync)
    end

    test "[:stacks, :fuse, :blown] telemetry fires when :google_books_fuse blows" do
      for _ <- 1..2 do
        ISBNResolver.resolve("9780743273565")
      end

      events =
        with_telemetry_capture([[:stacks, :fuse, :blown]], fn ->
          ISBNResolver.resolve("9780743273565")
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :google_books_fuse
             end),
             "expected [:stacks, :fuse, :blown] for :google_books_fuse, got: #{inspect(events)}"
    end

    test "search_by_title failures also contribute to :google_books_fuse melt count" do
      for _ <- 1..3 do
        ISBNResolver.search_by_title("Some Book", "Some Author")
      end

      assert :blown = :fuse.ask(:google_books_fuse, :sync)
    end
  end

  describe ":scraper_fuse — Enrichment.ScraperClient" do
    setup do
      install_test_fuse(:scraper_fuse, 2, 10_000)
      original_url = Application.get_env(:core, :scraper_service_url)
      original_client = Application.get_env(:core, :scraper_client)

      Application.put_env(:core, :scraper_service_url, "http://localhost:1")
      Application.put_env(:core, :scraper_client, Stacks.Enrichment.ScraperClient)

      on_exit(fn ->
        Application.put_env(:core, :scraper_service_url, original_url)
        Application.put_env(:core, :scraper_client, original_client)
        remove_fuse(:scraper_fuse)
        CircuitBreakers.install_all()
      end)
    end

    test "fuse is installed and starts :ok" do
      assert :ok = :fuse.ask(:scraper_fuse, :sync)
    end

    test "circuit blows after repeated connection failures and returns {:error, :circuit_open}" do
      for _ <- 1..3 do
        ScraperClient.scrape("9780743273565", "test_store")
      end

      assert {:error, :circuit_open} =
               ScraperClient.scrape("9780743273565", "test_store")
    end

    test "[:stacks, :fuse, :blown] telemetry fires when :scraper_fuse blows" do
      for _ <- 1..2 do
        ScraperClient.scrape("9780743273565", "test_store")
      end

      events =
        with_telemetry_capture([[:stacks, :fuse, :blown]], fn ->
          ScraperClient.scrape("9780743273565", "test_store")
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :scraper_fuse
             end),
             "expected [:stacks, :fuse, :blown] for :scraper_fuse, got: #{inspect(events)}"
    end
  end

  describe "probe URL construction" do
    # Regression: probe_google_books/0 used to hit the GB API without the
    # API key. Keyless GB requests ALWAYS fail (Google's anonymous pool
    # returns 429, quota_limit_value: "0"), so probe-based recovery was
    # structurally impossible — once blown, :google_books_fuse stayed
    # blown until the 5-min backstop and then re-blew under the next
    # burst. The probe must build its URL through the same helper the
    # resolver uses (ISBNResolver.google_books_url/1) so probe auth
    # always matches production auth.
    setup do
      original_key = Application.get_env(:core, :google_books_api_key)

      on_exit(fn ->
        if original_key do
          Application.put_env(:core, :google_books_api_key, original_key)
        else
          Application.delete_env(:core, :google_books_api_key)
        end
      end)

      :ok
    end

    test "google_books_probe_url/0 includes the configured API key" do
      Application.put_env(:core, :google_books_api_key, "probe-test-key")

      url = CircuitBreakers.google_books_probe_url()

      assert url =~ "https://www.googleapis.com/books/v1/volumes?"
      assert url =~ "q=frankenstein"
      assert url =~ "&key=probe-test-key"
    end

    test "google_books_probe_url/0 omits &key= when no key is configured" do
      Application.delete_env(:core, :google_books_api_key)

      url = CircuitBreakers.google_books_probe_url()

      assert url =~ "q=frankenstein"
      refute url =~ "key="
    end

    test "probe URL is built by the same helper production requests use" do
      Application.put_env(:core, :google_books_api_key, "probe-test-key")

      assert CircuitBreakers.google_books_probe_url() ==
               ISBNResolver.google_books_url("q=frankenstein&maxResults=1")
    end
  end

  describe "probe transport isolation" do
    @probe_env_keys [
      :vision_together_api_key,
      :brave_search_api_key,
      :searxng_url,
      :r2_endpoint_host
    ]

    setup do
      originals = Enum.map(@probe_env_keys, &{&1, Application.get_env(:core, &1)})

      on_exit(fn ->
        Enum.each(originals, fn
          {key, nil} -> Application.delete_env(:core, key)
          {key, value} -> Application.put_env(:core, key, value)
        end)
      end)

      :ok
    end

    test "no probe function reaches a real transport in test" do
      Application.put_env(:core, :vision_together_api_key, "probe-isolation-key")
      Application.put_env(:core, :brave_search_api_key, "probe-isolation-key")
      Application.put_env(:core, :searxng_url, "https://searxng.probe-isolation.test")
      Application.put_env(:core, :r2_endpoint_host, "r2.probe-isolation.test")

      test_pid = self()
      handler_id = "test-finch-dial-#{inspect(make_ref())}"

      :telemetry.attach(
        handler_id,
        [:finch, :request, :start],
        fn _event, _measurements, %{request: request}, _config ->
          send(test_pid, {:finch_dial, request.host})
        end,
        nil
      )

      results =
        try do
          Enum.map(
            [
              &CircuitBreakers.probe_vision/0,
              &CircuitBreakers.probe_scraper/0,
              &CircuitBreakers.probe_together_ai/0,
              &CircuitBreakers.probe_open_library/0,
              &CircuitBreakers.probe_google_books/0,
              &CircuitBreakers.probe_brave/0,
              &CircuitBreakers.probe_searxng/0,
              &CircuitBreakers.probe_r2/0
            ],
            & &1.()
          )
        after
          :telemetry.detach(handler_id)
        end

      assert Enum.all?(results, &(&1 == {:error, :outbound_disabled_in_test})),
             "expected every probe to be refused by the seamed test transport, got: " <>
               inspect(results)

      probe_hosts =
        ~w(openlibrary.org www.googleapis.com api.together.xyz api.search.brave.com) ++
          ~w(searxng.probe-isolation.test r2.probe-isolation.test)

      dialled = collect_finch_dials()
      dialled_probe_hosts = Enum.filter(dialled, &(&1 in probe_hosts))

      assert dialled_probe_hosts == [],
             "probe(s) reached the real transport for: #{inspect(dialled_probe_hosts)}"
    end

    defp collect_finch_dials do
      receive do
        {:finch_dial, host} -> [host | collect_finch_dials()]
      after
        0 -> []
      end
    end
  end

  describe "probe-based recovery" do
    setup do
      fuse_name = :test_probe_fuse

      remove_fuse(fuse_name)
      :fuse.install(fuse_name, {{:standard, 0, 60_000}, {:reset, 60_000}})

      on_exit(fn ->
        Application.delete_env(:core, :circuit_breaker_probe_overrides)
        remove_fuse(fuse_name)
        CircuitBreakers.install_all()
      end)

      {:ok, fuse_name: fuse_name}
    end

    test "telemetry handler for [:stacks, :fuse, :blown] is attached at startup" do
      handlers = :telemetry.list_handlers([:stacks, :fuse, :blown])

      assert Enum.any?(handlers, fn h ->
               h.id == "stacks-circuit-breakers-probe"
             end),
             "expected telemetry handler 'stacks-circuit-breakers-probe' to be attached"
    end

    test "probe resets fuse and emits [:stacks, :fuse, :recovered] on success", %{
      fuse_name: fuse_name
    } do
      Application.put_env(:core, :circuit_breaker_probe_overrides, %{
        fuse_name => fn -> :ok end
      })

      :fuse.melt(fuse_name)
      assert :blown = :fuse.ask(fuse_name, :sync)

      events =
        with_telemetry_capture([[:stacks, :fuse, :recovered]], fn ->
          send(Stacks.CircuitBreakers, {:probe, fuse_name})
          Process.sleep(50)
        end)

      assert :ok = :fuse.ask(fuse_name, :sync)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :recovered] and
                 meta.fuse_name == fuse_name and
                 meta.recovered_via == :probe
             end),
             "expected [:stacks, :fuse, :recovered] telemetry, got: #{inspect(events)}"
    end

    test "probe reschedules on failure and fuse stays blown", %{fuse_name: fuse_name} do
      test_pid = self()
      call_count = :counters.new(1, [])

      Application.put_env(:core, :circuit_breaker_probe_overrides, %{
        fuse_name => fn ->
          :counters.add(call_count, 1, 1)
          send(test_pid, {:probe_attempt, :counters.get(call_count, 1)})
          {:error, :service_down}
        end
      })

      :fuse.melt(fuse_name)
      assert :blown = :fuse.ask(fuse_name, :sync)

      send(Stacks.CircuitBreakers, {:probe, fuse_name})

      assert_receive {:probe_attempt, 1}, 500

      assert :blown = :fuse.ask(fuse_name, :sync)
    end

    test "probe is a no-op when fuse has already been reset (backstop fired first)", %{
      fuse_name: fuse_name
    } do
      call_count = :counters.new(1, [])

      Application.put_env(:core, :circuit_breaker_probe_overrides, %{
        fuse_name => fn ->
          :counters.add(call_count, 1, 1)
          :ok
        end
      })

      :fuse.melt(fuse_name)
      :fuse.reset(fuse_name)
      assert :ok = :fuse.ask(fuse_name, :sync)

      send(Stacks.CircuitBreakers, {:probe, fuse_name})
      Process.sleep(50)

      assert :counters.get(call_count, 1) == 0
    end

    test "[:stacks, :fuse, :recovered] telemetry fires with correct metadata on probe success", %{
      fuse_name: fuse_name
    } do
      Application.put_env(:core, :circuit_breaker_probe_overrides, %{
        fuse_name => fn -> :ok end
      })

      :fuse.melt(fuse_name)

      events =
        with_telemetry_capture([[:stacks, :fuse, :recovered]], fn ->
          send(Stacks.CircuitBreakers, {:probe, fuse_name})
          Process.sleep(50)
        end)

      assert [{[:stacks, :fuse, :recovered], %{}, meta}] = events
      assert meta.fuse_name == fuse_name
      assert meta.recovered_via == :probe
    end

    test "[:stacks, :fuse, :probe_failed] telemetry fires on failed probe", %{
      fuse_name: fuse_name
    } do
      Application.put_env(:core, :circuit_breaker_probe_overrides, %{
        fuse_name => fn -> {:error, :timeout} end
      })

      :fuse.melt(fuse_name)

      events =
        with_telemetry_capture([[:stacks, :fuse, :probe_failed]], fn ->
          send(Stacks.CircuitBreakers, {:probe, fuse_name})
          Process.sleep(50)
        end)

      assert [{[:stacks, :fuse, :probe_failed], %{}, meta}] = events
      assert meta.fuse_name == fuse_name
      assert meta.reason == :timeout
    end

    test "duplicate blown events do not create multiple probe loops", %{fuse_name: fuse_name} do
      test_pid = self()
      call_count = :counters.new(1, [])

      Application.put_env(:core, :circuit_breaker_probe_overrides, %{
        fuse_name => fn ->
          :counters.add(call_count, 1, 1)
          send(test_pid, :probe_called)
          {:error, :still_down}
        end
      })

      :fuse.melt(fuse_name)

      send(Stacks.CircuitBreakers, {:maybe_schedule_probe, fuse_name})
      send(Stacks.CircuitBreakers, {:maybe_schedule_probe, fuse_name})
      Process.sleep(50)

      send(Stacks.CircuitBreakers, {:probe, fuse_name})
      assert_receive :probe_called, 500

      assert :counters.get(call_count, 1) == 1
    end

    test "run_probe/1 handles fuse with no configured probe gracefully", %{fuse_name: fuse_name} do
      Application.delete_env(:core, :circuit_breaker_probe_overrides)

      :fuse.melt(fuse_name)

      events =
        with_telemetry_capture([[:stacks, :fuse, :probe_failed]], fn ->
          send(Stacks.CircuitBreakers, {:probe, fuse_name})
          Process.sleep(50)
        end)

      assert :blown = :fuse.ask(fuse_name, :sync)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :probe_failed] and
                 meta.fuse_name == fuse_name and
                 meta.reason == :no_probe
             end),
             "expected [:stacks, :fuse, :probe_failed] with reason :no_probe, got: #{inspect(events)}"
    end
  end

  defmodule RecordingProbeClient do
    @moduledoc false
    @behaviour Stacks.CircuitBreakers.ProbeHttpClientBehaviour

    @impl true
    def get(url, headers) do
      send(Process.whereis(:probe_recording_test), {:probe_get, url, headers})
      {:ok, 200}
    end
  end

  describe "third-party probes (neon / resend / nominatim)" do
    setup do
      Process.register(self(), :probe_recording_test)
      original = Application.get_env(:core, :circuit_breaker_probe_http_client)
      Application.put_env(:core, :circuit_breaker_probe_http_client, RecordingProbeClient)

      original_mailer = Application.get_env(:core, Stacks.Email.Mailer)

      on_exit(fn ->
        Application.put_env(:core, :circuit_breaker_probe_http_client, original)

        if original_mailer do
          Application.put_env(:core, Stacks.Email.Mailer, original_mailer)
        else
          Application.delete_env(:core, Stacks.Email.Mailer)
        end
      end)

      :ok
    end

    test "probe_resend without an api key cannot probe and says so" do
      Application.put_env(:core, Stacks.Email.Mailer, [])

      assert {:error, :api_key_not_configured} = CircuitBreakers.probe_resend()
      refute_receive {:probe_get, _, _}, 50
    end

    test "probe_resend authenticates exactly like the production mailer" do
      Application.put_env(:core, Stacks.Email.Mailer, api_key: "probe-resend-key")

      assert :ok = CircuitBreakers.probe_resend()

      assert_receive {:probe_get, "https://api.resend.com/domains", headers}
      assert {"authorization", "Bearer probe-resend-key"} in headers
    end

    test "probe_nominatim hits the public status endpoint" do
      assert :ok = CircuitBreakers.probe_nominatim()
      assert_receive {:probe_get, "https://nominatim.openstreetmap.org/status", _headers}
    end

    test "every registered fuse has a probe except the store-fuse family" do
      # a fuse without a probe stays blown until the reset backstop — every
      # named third party must be probeable
      for {fuse, _spec} <- [
            vision_fuse: nil,
            together_ai_fuse: nil,
            open_library_fuse: nil,
            google_books_fuse: nil,
            scraper_fuse: nil,
            brave_fuse: nil,
            searxng_fuse: nil,
            r2_fuse: nil,
            nominatim_fuse: nil,
            neon_fuse: nil,
            resend_fuse: nil,
            log_shipper_fuse: nil
          ] do
        assert function_exported?(
                 CircuitBreakers,
                 String.to_atom("probe_" <> probe_base(fuse)),
                 0
               ),
               "no probe function for #{fuse}"
      end
    end

    defp probe_base(fuse) do
      fuse |> Atom.to_string() |> String.replace_suffix("_fuse", "") |> probe_alias()
    end

    defp probe_alias("together_ai"), do: "together_ai"
    defp probe_alias(other), do: other
  end
end
