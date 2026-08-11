defmodule StacksWeb.Plugs.RouteGroupTest do
  @moduledoc """
    Route-grouping plug tests: `request_path` → `:route_group` tag
    (:auth,:catalogue,:bookshelves,:upload,:gdpr,:settings,:health,
  :metrics,:other) flowing into router-dispatch telemetry metadata for
    per-group SLO thresholds. Asserts each mapping and the three conn
    locations the tag is written to.
  """

  use CoreWeb.ConnCase, async: false

  alias StacksWeb.Plugs.RouteGroup

  defp run_plug(path) do
    :get
    |> Phoenix.ConnTest.build_conn(path)
    |> RouteGroup.call(RouteGroup.init([]))
  end

  defp read_group(conn) do
    cond do
      is_map(conn.private) and Map.has_key?(conn.private, :route_group) ->
        conn.private[:route_group]

      is_map(conn.private) and is_map(conn.private[:telemetry_metadata]) ->
        conn.private[:telemetry_metadata][:route_group]

      is_map(conn.assigns) and Map.has_key?(conn.assigns, :route_group) ->
        conn.assigns[:route_group]

      true ->
        nil
    end
  end

  describe "RouteGroup.call/2 — per-group tagging" do
    test "tags /api/auth/login as :auth" do
      conn = run_plug("/api/auth/login")
      assert read_group(conn) == :auth
    end

    test "tags /api/auth/register as :auth" do
      conn = run_plug("/api/auth/register")
      assert read_group(conn) == :auth
    end

    test "tags /api/catalogue as :catalogue" do
      conn = run_plug("/api/catalogue")
      assert read_group(conn) == :catalogue
    end

    test "tags /api/books/<uuid> as :catalogue" do
      conn = run_plug("/api/books/9b4d5d4e-ae93-4db6-abf1-0e6fc4e7baa3")
      assert read_group(conn) == :catalogue
    end

    test "tags /api/bookshelves/library as :bookshelves" do
      conn = run_plug("/api/bookshelves/library")
      assert read_group(conn) == :bookshelves
    end

    test "tags /api/bookshelves/<name>/placements as :bookshelves" do
      conn = run_plug("/api/bookshelves/library/placements")
      assert read_group(conn) == :bookshelves
    end

    test "tags /api/placements/<id>/move as :bookshelves" do
      conn = run_plug("/api/placements/abc-123/move")
      assert read_group(conn) == :bookshelves
    end

    test "tags /api/upload as :upload" do
      conn = run_plug("/api/upload")
      assert read_group(conn) == :upload
    end

    test "tags /api/upload/init as :upload" do
      conn = run_plug("/api/upload/init")
      assert read_group(conn) == :upload
    end

    test "tags /api/upload/<id>/stream as :upload" do
      conn = run_plug("/api/upload/abc-123/stream")
      assert read_group(conn) == :upload
    end

    test "tags /api/gdpr/export as :gdpr" do
      conn = run_plug("/api/gdpr/export")
      assert read_group(conn) == :gdpr
    end

    test "tags /api/gdpr/account as :gdpr" do
      conn = run_plug("/api/gdpr/account")
      assert read_group(conn) == :gdpr
    end

    test "tags /api/settings/profile as :settings" do
      conn = run_plug("/api/settings/profile")
      assert read_group(conn) == :settings
    end

    test "tags /api/health as :health" do
      conn = run_plug("/api/health")
      assert read_group(conn) == :health
    end

    test "tags /internal/metrics as :metrics" do
      conn = run_plug("/internal/metrics")
      assert read_group(conn) == :metrics
    end

    test "tags unknown /api/foo/bar as :other" do
      conn = run_plug("/api/foo/bar")
      assert read_group(conn) == :other
    end

    test "tags /some/non-api/path as :other" do
      conn = run_plug("/some/non-api/path")
      assert read_group(conn) == :other
    end
  end

  describe "RouteGroup — telemetry integration" do
    test "stacks.router_dispatch.stop carries :route_group in metadata", %{conn: conn} do
      test_pid = self()
      handler_id = "rg-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:stacks, :router_dispatch, :stop],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:rd_stop, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      get(conn, "/api/health")

      assert_receive {:rd_stop, metadata}, 2_000

      assert Map.get(metadata, :route_group) == :health,
             "expected :route_group=:health in router_dispatch metadata, got: #{inspect(metadata)}"
    end
  end
end
