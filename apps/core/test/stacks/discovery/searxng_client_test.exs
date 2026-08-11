defmodule Stacks.Discovery.SearxngClientTest do
  use ExUnit.Case, async: false

  alias Stacks.Discovery.SearxngClient

  describe "SearxngClient.search/2 — configuration guard" do
    setup do
      original = Application.get_env(:core, :searxng_url)
      on_exit(fn -> Application.put_env(:core, :searxng_url, original) end)
      :ok
    end

    test "returns {:error, :url_not_configured} when SEARXNG_URL is unset" do
      Application.delete_env(:core, :searxng_url)

      assert SearxngClient.search("book events near me") == {:error, :url_not_configured}
    end

    test "treats an empty SEARXNG_URL the same as unset" do
      Application.put_env(:core, :searxng_url, "")

      assert SearxngClient.search("book events near me") == {:error, :url_not_configured}
    end

    test "a configured URL gets past the guard and attempts the upstream call" do
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
      :fuse.install(:searxng_fuse, {{:standard, 1, 1_000}, {:reset, 60_000}})
      :fuse.melt(:searxng_fuse)
      :fuse.melt(:searxng_fuse)

      assert SearxngClient.search("book events near me") == {:error, :circuit_open}
    end
  end
end
