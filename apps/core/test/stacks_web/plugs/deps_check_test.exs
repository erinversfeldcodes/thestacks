defmodule StacksWeb.Plugs.DepsCheckTest do
  @moduledoc """
  Tests for `StacksWeb.Plugs.DepsCheck` — the synthetic dependency probe
  the SLO gate hits at `GET /internal/deps-check`.

  Two concerns:

    1. **Bearer auth is enforced upstream.** `MetricsAuth` runs before
       this plug in the endpoint pipeline, so a bare `/internal/deps-check`
       GET without a valid Bearer token must 401. An integration test
       covers this because unit-calling the plug directly would bypass
       MetricsAuth entirely.
    2. **Result shape is stable.** The SLO gate treats any non-200 as
       "dep is down" and folds it into availability. A successful probe
       must return 200 with JSON `{"searxng":"ok"}`; a SearXNG failure
       must return 503 with the failing dep's key.

  Uses MockSearxngClient (registered in `apps/core/config/test.exs`),
  which stores per-process responses so `async: true` is safe.
  """

  use CoreWeb.ConnCase, async: true

  alias Stacks.Discovery.MockSearxngClient

  @valid_token "test-deps-check-token-for-issue-136"

  setup do
    original = Application.get_env(:core, :metrics_scrape_token)
    Application.put_env(:core, :metrics_scrape_token, @valid_token)

    on_exit(fn ->
      MockSearxngClient.clear()

      if is_nil(original) do
        Application.delete_env(:core, :metrics_scrape_token)
      else
        Application.put_env(:core, :metrics_scrape_token, original)
      end
    end)

    :ok
  end

  defp authed(conn) do
    put_req_header(conn, "authorization", "Bearer #{@valid_token}")
  end

  describe "GET /internal/deps-check — success path" do
    test "returns 200 and searxng=ok when the SearXNG client succeeds", %{conn: conn} do
      MockSearxngClient.put_response({:ok, [%{title: "t", url: "u", description: "d"}]})

      conn = conn |> authed() |> get("/internal/deps-check")

      assert conn.status == 200

      assert get_resp_header(conn, "content-type")
             |> Enum.any?(&String.starts_with?(&1, "application/json"))

      assert Jason.decode!(conn.resp_body) == %{"searxng" => "ok"}
    end

    test "returns 200 even with an empty result set (ok, no hits)", %{conn: conn} do
      MockSearxngClient.put_response({:ok, []})

      conn = conn |> authed() |> get("/internal/deps-check")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"searxng" => "ok"}
    end
  end

  describe "GET /internal/deps-check — failure path" do
    test "returns 503 with error:<reason> when SearXNG errors", %{conn: conn} do
      MockSearxngClient.put_response({:error, :url_not_configured})

      conn = conn |> authed() |> get("/internal/deps-check")

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["searxng"] =~ "error:"
      assert body["searxng"] =~ "url_not_configured"
    end
  end

  describe "GET /internal/deps-check — auth" do
    test "401 without a bearer token (auth enforced upstream by MetricsAuth)", %{conn: conn} do
      conn = get(conn, "/internal/deps-check")

      assert conn.status == 401
    end

    test "401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get("/internal/deps-check")

      assert conn.status == 401
    end
  end
end
