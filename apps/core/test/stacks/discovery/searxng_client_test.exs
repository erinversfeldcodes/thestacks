defmodule Stacks.Discovery.SearxngClientTest do
  # async: false — both describes below mutate process-global state (the
  # `:searxng_url` application env and the node-wide `:searxng_fuse`).
  use ExUnit.Case, async: false

  alias Stacks.Discovery.SearxngClient

  # ⚠️ **What used to be here, and why it is gone (Issue #330).**
  #
  # This file was a single `describe "MockSearxngClient"` block of four tests that
  # called `MockSearxngClient.put_response(x)` and then asserted `search/2`
  # returned `x`. It never referenced `Stacks.Discovery.SearxngClient` — the module
  # the file is named after — so it could not fail for any change to the real
  # client. It asserted that Agent-backed storage stores things.
  #
  # Coverage note: nothing was lost. The mock's put/clear machinery is exercised
  # for real by `source_discovery_job_test.exs` and
  # `discover_author_sources_job_test.exs`, which use `put_response` to steer the
  # production `SourceDiscoveryJob` / `DiscoverAuthorSourcesJob` through the
  # behaviour seam — there the mock is a means, and the assertion is about
  # production code. The removed tests were never a real guarantee.
  #
  # What follows is the coverage the file was *missing*: the two guards in the
  # real `SearxngClient.search/2` that short-circuit before any HTTP call, and so
  # are reachable in a unit test without a network or a live SearXNG.

  describe "SearxngClient.search/2 — configuration guard" do
    setup do
      original = Application.get_env(:core, :searxng_url)
      on_exit(fn -> Application.put_env(:core, :searxng_url, original) end)
      :ok
    end

    test "returns {:error, :url_not_configured} when SEARXNG_URL is unset" do
      # A missing instance URL must be reported as a distinct, actionable error
      # rather than being interpolated into "/search?q=..." and dialled as a
      # relative URL.
      Application.delete_env(:core, :searxng_url)

      assert SearxngClient.search("book events near me") == {:error, :url_not_configured}
    end

    test "treats an empty SEARXNG_URL the same as unset" do
      # An env var exported as "" is the common shape of "not configured" in a
      # container, and is not distinguishable from unset by the operator.
      Application.put_env(:core, :searxng_url, "")

      assert SearxngClient.search("book events near me") == {:error, :url_not_configured}
    end

    test "a configured URL gets past the guard and attempts the upstream call" do
      # Positive control for the two assertions above: with a URL present the
      # function no longer returns :url_not_configured. The URL points at a
      # closed port, so this exercises the real Finch error branch and must
      # surface a transport error — NOT the configuration error.
      Application.put_env(:core, :searxng_url, "http://127.0.0.1:1")

      assert {:error, reason} = SearxngClient.search("book events near me")

      refute reason == :url_not_configured,
             "the config guard fired despite :searxng_url being set — the guard is inverted"

      refute reason == :circuit_open,
             "expected a transport error from the closed port, got a blown fuse"
    end
  end

  describe "SearxngClient.search/2 — circuit breaker" do
    setup do
      original = Application.get_env(:core, :searxng_url)
      Application.put_env(:core, :searxng_url, "http://127.0.0.1:1")

      on_exit(fn ->
        Application.put_env(:core, :searxng_url, original)
        :fuse.reset(:searxng_fuse)
      end)

      :ok
    end

    test "returns {:error, :circuit_open} without touching the upstream when the fuse is blown" do
      # The point of the fuse is that a down SearXNG stops costing us a 15s
      # receive_timeout per call. If this branch regressed, source discovery
      # would keep dialling a dead instance and the only symptom would be
      # latency.
      :fuse.install(:searxng_fuse, {{:standard, 1, 1_000}, {:reset, 60_000}})
      :fuse.melt(:searxng_fuse)
      :fuse.melt(:searxng_fuse)

      assert SearxngClient.search("book events near me") == {:error, :circuit_open}
    end
  end
end
