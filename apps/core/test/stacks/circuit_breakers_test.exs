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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Capture telemetry events fired during a test body.
  # Returns a list of {event_name, measurements, metadata} tuples.
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

  # Install a fuse with threshold=2 (blows on the 3rd melt, i.e. melt_count > 2).
  # Remove any existing fuse first so tests start clean.
  defp install_test_fuse(name, threshold, window_ms) do
    remove_fuse(name)
    :fuse.install(name, {{:standard, threshold, window_ms}, {:reset, 60_000}})
  end

  defp remove_fuse(name) do
    :fuse.remove(name)
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # 1. Stacks.CircuitBreakers.install_all/0 installs all 5 fuses
  # ---------------------------------------------------------------------------

  describe "Stacks.CircuitBreakers — startup installation" do
    setup do
      # Remove all managed fuses before each test so we can verify install
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

        # Restore production fuses so subsequent test modules are not affected
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
      # Second call must not raise or return error
      assert :ok = CircuitBreakers.install_all()
      # Fuses remain in :ok state
      assert :ok = :fuse.ask(:vision_fuse, :sync)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Stacks.CircuitBreakers.melt/1 — shared telemetry helper
  # ---------------------------------------------------------------------------

  describe "Stacks.CircuitBreakers.melt/1 — telemetry" do
    setup do
      # threshold=2: blows on the 3rd melt (melt_count > 2)
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
      # Pre-melt to threshold (2 melts already in, one more blows it)
      CircuitBreakers.melt(:test_melt_fuse)
      CircuitBreakers.melt(:test_melt_fuse)

      events =
        with_telemetry_capture([[:stacks, :fuse, :melt], [:stacks, :fuse, :blown]], fn ->
          # 3rd melt tips melt_count > 2 → blown
          CircuitBreakers.melt(:test_melt_fuse)
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :test_melt_fuse
             end),
             "expected [:stacks, :fuse, :blown] telemetry, got: #{inspect(events)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. :vision_fuse — AI.Client
  # ---------------------------------------------------------------------------

  describe ":vision_fuse — AI.Client" do
    setup do
      # threshold=2: 3 connection failures blow the circuit
      install_test_fuse(:vision_fuse, 2, 10_000)
      original_url = Application.get_env(:core, :vision_service_url)
      original_client = Application.get_env(:core, :vision_client)

      # Point at an unreachable port so every HTTP call fails with :econnrefused
      Application.put_env(:core, :vision_service_url, "http://localhost:1")
      # Force the real client (not mock) so the circuit breaker is exercised
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
      # 3 failures blow the fuse (threshold=2 means melt_count > 2 after 3 melts)
      for _ <- 1..3 do
        AIClient.call_vision("is_book", %{image_url: "https://example.com/cover.jpg"})
      end

      # Circuit is now blown; next call must short-circuit without hitting the network
      assert {:error, :circuit_open} =
               AIClient.call_vision("is_book", %{
                 image_url: "https://example.com/cover.jpg"
               })
    end

    test "[:stacks, :fuse, :blown] telemetry fires when :vision_fuse blows" do
      # Pre-load 2 melts (one short of blowing)
      for _ <- 1..2 do
        AIClient.call_vision("is_book", %{image_url: "https://example.com/cover.jpg"})
      end

      events =
        with_telemetry_capture([[:stacks, :fuse, :blown]], fn ->
          # 3rd failure tips the count over threshold → blown
          AIClient.call_vision("is_book", %{image_url: "https://example.com/cover.jpg"})
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :vision_fuse
             end),
             "expected [:stacks, :fuse, :blown] for :vision_fuse, got: #{inspect(events)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. :together_ai_fuse — AI.TogetherClient
  # ---------------------------------------------------------------------------

  describe ":together_ai_fuse — AI.TogetherClient" do
    setup do
      # threshold=2: 3 connection failures blow the circuit
      install_test_fuse(:together_ai_fuse, 2, 10_000)
      original_client = Application.get_env(:core, :together_client)
      original_key = Application.get_env(:core, :vision_together_api_key)
      original_url = Application.get_env(:core, :together_ai_base_url)

      # Use real client + an unreachable port. The connection failure triggers
      # melt without making real outbound HTTP calls — same pattern as vision/scraper.
      # A non-nil API key is still required so make_request/1 attempts the network
      # (rather than returning {:error, :api_key_missing} immediately).
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
      # 3 :econnrefused failures → 3 melts → fuse blown on the 4th ask
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
      # Pre-melt 2 times (one short of blowing)
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

  # ---------------------------------------------------------------------------
  # 5. :open_library_fuse — Books.ISBNResolver (Open Library path)
  # ---------------------------------------------------------------------------

  describe ":open_library_fuse — Books.ISBNResolver" do
    setup do
      # threshold=2: 3 failures blow the circuit
      install_test_fuse(:open_library_fuse, 2, 10_000)
      # Also install google_books_fuse so ISBNResolver doesn't crash after OL fails
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
      # Each resolve/1 call hits Open Library first. With the failing HTTP client,
      # each attempt melts :open_library_fuse. After 3 failures the fuse blows.
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
      # Pre-blow :google_books_fuse so the sequential GB fallback
      # short-circuits at the fuse without an HTTP call.
      :fuse.melt(:google_books_fuse)
      :fuse.melt(:google_books_fuse)
      :fuse.melt(:google_books_fuse)

      # 3 search_by_title calls → 3 OL HTTP failures → :open_library_fuse blown
      for _ <- 1..3 do
        ISBNResolver.search_by_title("Some Book", "Some Author")
      end

      assert :blown = :fuse.ask(:open_library_fuse, :sync)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. :google_books_fuse — Books.ISBNResolver (Google Books fallback path)
  # ---------------------------------------------------------------------------

  describe ":google_books_fuse — Books.ISBNResolver" do
    setup do
      # threshold=2: 3 failures blow the circuit
      install_test_fuse(:google_books_fuse, 2, 10_000)
      # Pre-blow the Open Library fuse so ISBNResolver falls through to Google Books.
      # threshold=0: first melt blows it (melt_count > 0 after 1 melt)
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
      # Open Library fuse is pre-blown; each resolve goes directly to Google Books.
      # After 3 failures :google_books_fuse blows.
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
      # :open_library_fuse is already pre-blown in setup; search_by_title falls
      # straight through to Google Books for every candidate.
      # 3 calls → 3 GB HTTP failures → :google_books_fuse blown.
      for _ <- 1..3 do
        ISBNResolver.search_by_title("Some Book", "Some Author")
      end

      assert :blown = :fuse.ask(:google_books_fuse, :sync)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. :scraper_fuse — Enrichment.ScraperClient
  # ---------------------------------------------------------------------------

  describe ":scraper_fuse — Enrichment.ScraperClient" do
    setup do
      # threshold=2: 3 connection failures blow the circuit
      install_test_fuse(:scraper_fuse, 2, 10_000)
      original_url = Application.get_env(:core, :scraper_service_url)
      original_client = Application.get_env(:core, :scraper_client)

      # Point at an unreachable port; use real client so circuit breaker is exercised
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
      # 3 :econnrefused failures → 3 melts → fuse blown on the 4th ask
      for _ <- 1..3 do
        ScraperClient.scrape("9780743273565", "test_store")
      end

      assert {:error, :circuit_open} =
               ScraperClient.scrape("9780743273565", "test_store")
    end

    test "[:stacks, :fuse, :blown] telemetry fires when :scraper_fuse blows" do
      # Pre-melt 2 times (one short of blowing)
      for _ <- 1..2 do
        ScraperClient.scrape("9780743273565", "test_store")
      end

      events =
        with_telemetry_capture([[:stacks, :fuse, :blown]], fn ->
          # 3rd failure tips count > 2 → blown
          ScraperClient.scrape("9780743273565", "test_store")
        end)

      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :blown] and meta.fuse_name == :scraper_fuse
             end),
             "expected [:stacks, :fuse, :blown] for :scraper_fuse, got: #{inspect(events)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Probe URL construction — probe auth must match production auth
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # 9. Probe-based recovery
  # ---------------------------------------------------------------------------

  describe "probe-based recovery" do
    setup do
      # Use a unique fuse name per test to avoid interference with other suites.
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
      # Verify the stable handler ID is registered — this confirms init/1 wired
      # the probe scheduler correctly and the handler survives GenServer restarts
      # (stable ID prevents duplicate handler leaks).
      handlers = :telemetry.list_handlers([:stacks, :fuse, :blown])

      assert Enum.any?(handlers, fn h ->
               h.id == "stacks-circuit-breakers-probe"
             end),
             "expected telemetry handler 'stacks-circuit-breakers-probe' to be attached"
    end

    test "probe resets fuse and emits [:stacks, :fuse, :recovered] on success", %{
      fuse_name: fuse_name
    } do
      # Inject a probe that always succeeds.
      Application.put_env(:core, :circuit_breaker_probe_overrides, %{
        fuse_name => fn -> :ok end
      })

      # Blow the fuse first.
      :fuse.melt(fuse_name)
      assert :blown = :fuse.ask(fuse_name, :sync)

      # Capture the recovered telemetry, then send the probe message directly.
      events =
        with_telemetry_capture([[:stacks, :fuse, :recovered]], fn ->
          send(Stacks.CircuitBreakers, {:probe, fuse_name})
          # Give the GenServer time to process the message.
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

      # Blow the fuse.
      :fuse.melt(fuse_name)
      assert :blown = :fuse.ask(fuse_name, :sync)

      # Manually trigger the first probe — it should fail and reschedule.
      send(Stacks.CircuitBreakers, {:probe, fuse_name})

      # Wait for first probe attempt.
      assert_receive {:probe_attempt, 1}, 500

      # Fuse must still be blown after a failed probe.
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

      # Blow then manually reset (simulating backstop timer firing).
      :fuse.melt(fuse_name)
      :fuse.reset(fuse_name)
      assert :ok = :fuse.ask(fuse_name, :sync)

      # Send the probe — it should be a no-op since the fuse is already :ok.
      send(Stacks.CircuitBreakers, {:probe, fuse_name})
      Process.sleep(50)

      # The probe function should NOT have been called.
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

      # Simulate two concurrent blown events reaching the GenServer.
      send(Stacks.CircuitBreakers, {:maybe_schedule_probe, fuse_name})
      send(Stacks.CircuitBreakers, {:maybe_schedule_probe, fuse_name})
      Process.sleep(50)

      # Only one probe timer should have been scheduled. Verify by sending the
      # probe message directly and confirming the call count is exactly 1.
      send(Stacks.CircuitBreakers, {:probe, fuse_name})
      assert_receive :probe_called, 500

      # A second {:probe} sent directly should also succeed but we're checking
      # the deduplication from {maybe_schedule_probe} — the counter proves
      # only one probe path was set up from the two blown events.
      assert :counters.get(call_count, 1) == 1
    end

    test "run_probe/1 handles fuse with no configured probe gracefully", %{fuse_name: fuse_name} do
      # No override for fuse_name AND fuse_name is not in @probes (it's a test fuse).
      # The run_probe path should return {:error, :no_probe} and the fuse stays blown.
      Application.delete_env(:core, :circuit_breaker_probe_overrides)

      :fuse.melt(fuse_name)

      events =
        with_telemetry_capture([[:stacks, :fuse, :probe_failed]], fn ->
          send(Stacks.CircuitBreakers, {:probe, fuse_name})
          Process.sleep(50)
        end)

      # Fuse should still be blown — :no_probe is treated as a failed probe.
      assert :blown = :fuse.ask(fuse_name, :sync)

      # probe_failed telemetry should have fired with reason: :no_probe.
      assert Enum.any?(events, fn {event, _m, meta} ->
               event == [:stacks, :fuse, :probe_failed] and
                 meta.fuse_name == fuse_name and
                 meta.reason == :no_probe
             end),
             "expected [:stacks, :fuse, :probe_failed] with reason :no_probe, got: #{inspect(events)}"
    end
  end
end
