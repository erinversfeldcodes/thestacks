defmodule Stacks.Books.EnrichmentDiagnosticsTest do
  @moduledoc """
  Diagnostics for the EnrichBookJob/ISBNResolver path: reproduces four
  observed/hypothesised failure modes of the barcode-upload E2E and
  asserts the Tier-2 telemetry fires for each, so any future failure
  leaves its fingerprint in the logs (cache-poisoned negative, provider
  outage, fuse open, placeholder-never-enriched).
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.ISBNResolver
  alias Stacks.Books.ISBNResolverCache
  alias Stacks.Books.MockHttpClient
  alias Stacks.CircuitBreakers
  alias Stacks.Workers.EnrichBookJob

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "enrichment-diagnostics-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp drain_telemetry, do: drain_telemetry([])

  defp drain_telemetry(acc) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defmodule CountingMockHttpClient do
    @moduledoc false
    @behaviour Stacks.Books.HttpClientBehaviour

    alias Stacks.Books.MockHttpClient, as: Inner

    @impl true
    def get(url) do
      bump_count()
      Inner.get(url)
    end

    def bump_count do
      pid = find_test_owner(Process.get(:"$callers", [self()]))
      :counters.add(counter_for(pid), 1, 1)
    end

    def reset(pid \\ self()) do
      :counters.put(counter_for(pid), 1, 0)
    end

    def count(pid \\ self()) do
      :counters.get(counter_for(pid), 1)
    end

    defp counter_for(pid) do
      key = {__MODULE__, pid}

      case :persistent_term.get(key, :undefined) do
        :undefined ->
          ref = :counters.new(1, [:atomics])
          :persistent_term.put(key, ref)
          ref

        ref ->
          ref
      end
    end

    defp find_test_owner([]), do: self()
    defp find_test_owner([pid | _]), do: pid
  end

  describe "Tier 2 telemetry — [:stacks, :enrichment, :resolver, :outcome]" do
    setup do
      :fuse.reset(:open_library_fuse)
      :fuse.reset(:google_books_fuse)
      attach_telemetry([[:stacks, :enrichment, :resolver, :outcome]])
      :ok
    end

    test "emits outcome=:ok and source=:open_library on a successful OL hit" do
      isbn = "9780156001311"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "The Name of the Rose",
             "authors" => [%{"name" => "Umberto Eco"}],
             "publish_date" => "1980"
           }
         }}
      )

      assert :ok = perform_job(EnrichBookJob, %{"isbn" => isbn})

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :ok, source: :open_library}}
    end

    test "emits outcome=:not_found when both upstreams return empty" do
      isbn = "9780000000019"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response("openlibrary.org/api/books", {:ok, %{}})
      MockHttpClient.put_response("googleapis.com", {:ok, %{}})

      assert {:error, :not_found} = perform_job(EnrichBookJob, %{"isbn" => isbn})

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :not_found, source: nil}}
    end

    test "emits outcome=:unexpected_status when both upstreams return 5xx" do
      isbn = "9780000000026"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :unexpected_status})
      MockHttpClient.put_response("googleapis.com", {:error, :unexpected_status})

      assert {:error, :unexpected_status} = perform_job(EnrichBookJob, %{"isbn" => isbn})

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :unexpected_status, source: nil}}

      assert :miss = ISBNResolverCache.get(isbn)
    end

    test "emits outcome=:malformed_response when both upstreams return garbled JSON" do
      isbn = "9780000000033"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :malformed_response})
      MockHttpClient.put_response("googleapis.com", {:error, :malformed_response})

      assert {:error, :malformed_response} = perform_job(EnrichBookJob, %{"isbn" => isbn})

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :malformed_response, source: nil}}

      assert :miss = ISBNResolverCache.get(isbn)
    end

    test "emits outcome=:transport_error when both upstreams fail to connect" do
      isbn = "9780000000040"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :transport_error})
      MockHttpClient.put_response("googleapis.com", {:error, :transport_error})

      assert {:error, :transport_error} = perform_job(EnrichBookJob, %{"isbn" => isbn})

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :transport_error, source: nil}}

      assert :miss = ISBNResolverCache.get(isbn)
    end

    test "emits outcome=:timeout when both upstreams time out" do
      isbn = "9780000000057"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      MockHttpClient.put_response("openlibrary.org/api/books", {:error, :timeout})
      MockHttpClient.put_response("googleapis.com", {:error, :timeout})

      assert {:error, :timeout} = perform_job(EnrichBookJob, %{"isbn" => isbn})

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :timeout, source: nil}}

      assert :miss = ISBNResolverCache.get(isbn)
    end
  end

  describe "Tier 2 telemetry — [:stacks, :isbn_resolver_cache, :negative_stored]" do
    setup do
      attach_telemetry([[:stacks, :isbn_resolver_cache, :negative_stored]])
      ISBNResolverCache.invalidate_all()
      on_exit(fn -> ISBNResolverCache.invalidate_all() end)
      :ok
    end

    test "fires when a {:error, :not_found} is cached, with ttl_ms metadata" do
      isbn = "9780000000024"

      assert :ok = ISBNResolverCache.put(isbn, {:error, :not_found})

      assert_receive {:telemetry, [:stacks, :isbn_resolver_cache, :negative_stored],
                      %{count: 1, ttl_ms: ttl_ms}, %{isbn: ^isbn}}

      assert ttl_ms == 60 * 60 * 1000
    end

    test "does NOT fire when a positive {:ok, _} is cached" do
      isbn = "9780000000031"

      assert :ok = ISBNResolverCache.put(isbn, {:ok, %{title: "Real", source: :open_library}})

      refute_receive {:telemetry, [:stacks, :isbn_resolver_cache, :negative_stored], _, _}
    end

    test "does NOT fire when {:error, :circuit_open} is dropped (not cached)" do
      isbn = "9780000000048"

      assert :ok = ISBNResolverCache.put(isbn, {:error, :circuit_open})

      refute_receive {:telemetry, [:stacks, :isbn_resolver_cache, :negative_stored], _, _}
    end
  end

  describe "Scenario 1 — negative cache poison" do
    setup do
      original_cache = Application.get_env(:core, :isbn_resolver_cache_enabled)
      original_client = Application.get_env(:core, :isbn_http_client)

      Application.put_env(:core, :isbn_resolver_cache_enabled, true)
      Application.put_env(:core, :isbn_http_client, CountingMockHttpClient)

      :fuse.reset(:open_library_fuse)
      :fuse.reset(:google_books_fuse)

      ISBNResolverCache.invalidate_all()
      CountingMockHttpClient.reset()

      on_exit(fn ->
        Application.put_env(:core, :isbn_resolver_cache_enabled, original_cache)
        Application.put_env(:core, :isbn_http_client, original_client)
        ISBNResolverCache.invalidate_all()
      end)

      attach_telemetry([
        [:stacks, :isbn_resolver_cache, :negative_stored],
        [:stacks, :enrichment, :resolver, :outcome]
      ])

      :ok
    end

    @tag :diagnostics_scenario_1
    test "negative cache hit blocks subsequent legitimate calls within TTL" do
      isbn = "9780156001311"

      assert :ok = ISBNResolverCache.put(isbn, {:error, :not_found})

      assert_receive {:telemetry, [:stacks, :isbn_resolver_cache, :negative_stored], %{count: 1},
                      %{isbn: ^isbn}}

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "The Name of the Rose",
             "authors" => [%{"name" => "Umberto Eco"}],
             "publish_date" => "1980"
           }
         }}
      )

      CountingMockHttpClient.reset()

      assert {:error, :not_found} = ISBNResolver.resolve(isbn)

      assert CountingMockHttpClient.count() == 0,
             "resolver hit the network despite a cached negative entry"
    end

    @tag :diagnostics_scenario_1
    test "negative cache entry expires after the 1h TTL" do
      isbn = "9780156001311"

      expired_at = System.monotonic_time(:millisecond) - 1
      :ets.insert(:isbn_resolver_cache, {isbn, {:error, :not_found}, expired_at})

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "The Name of the Rose",
             "authors" => [%{"name" => "Umberto Eco"}],
             "publish_date" => "1980"
           }
         }}
      )

      CountingMockHttpClient.reset()

      assert {:ok, %{title: "The Name of the Rose"}} = ISBNResolver.resolve(isbn)
      assert CountingMockHttpClient.count() >= 1
    end
  end

  describe "Scenario 2 — circuit breaker open" do
    setup do
      :fuse.remove(:open_library_fuse)
      :fuse.remove(:google_books_fuse)

      :fuse.install(:open_library_fuse, {{:standard, 1, 60_000}, {:reset, 60_000}})
      :fuse.install(:google_books_fuse, {{:standard, 1, 60_000}, {:reset, 60_000}})

      :fuse.melt(:open_library_fuse)
      :fuse.melt(:open_library_fuse)
      :fuse.melt(:google_books_fuse)
      :fuse.melt(:google_books_fuse)

      assert :blown = :fuse.ask(:open_library_fuse, :sync)
      assert :blown = :fuse.ask(:google_books_fuse, :sync)

      ISBNResolverCache.invalidate_all()
      attach_telemetry([[:stacks, :enrichment, :resolver, :outcome]])

      on_exit(fn ->
        :fuse.reset(:open_library_fuse)
        :fuse.reset(:google_books_fuse)
        ISBNResolverCache.invalidate_all()
        CircuitBreakers.install_all()
      end)

      :ok
    end

    @tag :diagnostics_scenario_2
    test "blown OL + GB fuses return :circuit_open and do NOT poison the cache" do
      isbn = "9780156001311"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      original = Application.get_env(:core, :isbn_resolver_cache_enabled)
      Application.put_env(:core, :isbn_resolver_cache_enabled, true)
      on_exit(fn -> Application.put_env(:core, :isbn_resolver_cache_enabled, original) end)

      result = perform_job(EnrichBookJob, %{"isbn" => isbn})
      assert {:error, :circuit_open} = result

      assert :miss = ISBNResolverCache.get(isbn)

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :circuit_open, source: nil}}
    end
  end

  describe "Scenario 3 — 5xx storm" do
    setup do
      original_client = Application.get_env(:core, :isbn_http_client)
      Application.put_env(:core, :isbn_http_client, Stacks.Testing.FailingHttpClient)

      ISBNResolverCache.invalidate_all()

      :fuse.reset(:open_library_fuse)
      :fuse.reset(:google_books_fuse)

      attach_telemetry([[:stacks, :enrichment, :resolver, :outcome]])

      on_exit(fn ->
        Application.put_env(:core, :isbn_http_client, original_client)
        :fuse.reset(:open_library_fuse)
        :fuse.reset(:google_books_fuse)
        ISBNResolverCache.invalidate_all()
        CircuitBreakers.install_all()
      end)

      :ok
    end

    @tag :diagnostics_scenario_3
    test "transport storm exhausts EnrichBookJob retries without poisoning cache" do
      isbn = "9780156001311"

      {:ok, _book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      for _ <- 1..5 do
        :fuse.reset(:open_library_fuse)
        :fuse.reset(:google_books_fuse)
        assert {:error, _} = perform_job(EnrichBookJob, %{"isbn" => isbn})
      end

      assert :miss = ISBNResolverCache.get(isbn)

      events = drain_telemetry()

      outcomes =
        for {[:stacks, :enrichment, :resolver, :outcome], _, %{outcome: o}} <- events, do: o

      assert length(outcomes) == 5

      assert Enum.all?(
               outcomes,
               &(&1 in [:transport_error, :timeout, :not_found, :circuit_open])
             )

      refute Enum.any?(outcomes, &(&1 == :ok))
    end

    @tag :diagnostics_scenario_3
    test "after 5xx storm clears, fresh enqueue succeeds and updates the book" do
      isbn = "9780156001311"

      {:ok, book} =
        Books.create(%{
          "isbn" => isbn,
          "title" => "ISBN #{isbn}",
          "visibility_tier" => "public"
        })

      for _ <- 1..5 do
        :fuse.reset(:open_library_fuse)
        :fuse.reset(:google_books_fuse)
        assert {:error, _} = perform_job(EnrichBookJob, %{"isbn" => isbn})
      end

      Application.put_env(:core, :isbn_http_client, Stacks.Books.MockHttpClient)
      :fuse.reset(:open_library_fuse)
      :fuse.reset(:google_books_fuse)

      MockHttpClient.put_response(
        "openlibrary.org/api/books",
        {:ok,
         %{
           "ISBN:#{isbn}" => %{
             "title" => "The Name of the Rose",
             "authors" => [%{"name" => "Umberto Eco"}],
             "publish_date" => "1980"
           }
         }}
      )

      _ = drain_telemetry()

      assert :ok = perform_job(EnrichBookJob, %{"isbn" => isbn})

      updated = Repo.get!(Stacks.Books.Book, book.id)
      assert updated.title == "The Name of the Rose"

      assert_receive {:telemetry, [:stacks, :enrichment, :resolver, :outcome], %{count: 1},
                      %{isbn: ^isbn, outcome: :ok, source: :open_library}}
    end
  end

  describe "Scenario 4 — apply_metadata edge cases" do
    @edge_cases_passing [
      {"very long title (>1000 chars)", %{"title" => String.duplicate("a", 1100)}},
      {"unicode + emoji", %{"title" => "Le Café 📚 — Eco's Library"}},
      {"newlines and CRs in title", %{"title" => "Line one\nLine two\r\nLine three"}},
      {"embedded quotes", %{"title" => ~s(The "Name" of the 'Rose'\\)}},
      {"negative page_count", %{"number_of_pages" => -42}},
      {"future publication_year", %{"publish_date" => "99999"}}
    ]

    @edge_cases_pending [
      {"missing optional keys",
       %{
         "title" => "Bare Minimum",
         "authors" => nil,
         "publish_date" => nil,
         "number_of_pages" => nil,
         "cover" => nil,
         "publishers" => nil
       }},
      {"non-integer page_count (binary)", %{"number_of_pages" => "lots"}},
      {"empty title", %{"title" => ""}},
      {"nil title", %{"title" => nil}}
    ]

    setup do
      attach_telemetry([[:stacks, :enrichment, :resolver, :outcome]])
      :ok
    end

    for {label, override} <- @edge_cases_passing do
      @tag :diagnostics_scenario_4
      test "apply_metadata does not raise for #{label}", _context do
        run_edge_case(unquote(label), unquote(Macro.escape(override)))
      end
    end

    for {label, override} <- @edge_cases_pending do
      @tag :diagnostics_scenario_4
      @tag :pending_apply_metadata_hardening
      test "apply_metadata does not raise for #{label}", _context do
        run_edge_case(unquote(label), unquote(Macro.escape(override)))
      end
    end
  end

  defp run_edge_case(label, override) do
    isbn = unique_isbn()

    {:ok, _book} =
      Books.create(%{
        "isbn" => isbn,
        "title" => "ISBN #{isbn}",
        "visibility_tier" => "public"
      })

    response = Map.merge(base_ol_payload(), override)

    MockHttpClient.put_response(
      "openlibrary.org/api/books",
      {:ok, %{"ISBN:#{isbn}" => response}}
    )

    MockHttpClient.put_response("googleapis.com", {:ok, %{}})

    result =
      try do
        perform_job(EnrichBookJob, %{"isbn" => isbn})
      rescue
        e ->
          flunk(
            "EnrichBookJob raised on edge case #{label}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end

    assert match?(:ok, result) or match?({:ok, _}, result) or match?({:error, _}, result),
           "unexpected return for #{label}: #{inspect(result)}"
  end

  defp base_ol_payload do
    %{
      "title" => "A Title",
      "authors" => [%{"name" => "An Author"}],
      "publish_date" => "1980",
      "number_of_pages" => 200,
      "cover" => %{"large" => "https://covers.openlibrary.org/b/id/1-L.jpg"},
      "publishers" => [%{"name" => "Publisher"}],
      "key" => "/books/OL1M"
    }
  end

  defp unique_isbn do
    n = System.unique_integer([:positive])
    suffix = String.pad_leading(Integer.to_string(rem(n, 10_000)), 4, "0")
    base = "97801560" <> suffix
    base <> Integer.to_string(isbn13_checksum(base))
  end

  defp isbn13_checksum(digits12) when is_binary(digits12) and byte_size(digits12) == 12 do
    sum =
      digits12
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {d, i} ->
        weight = if rem(i, 2) == 0, do: 1, else: 3
        String.to_integer(d) * weight
      end)
      |> Enum.sum()

    rem(10 - rem(sum, 10), 10)
  end
end
