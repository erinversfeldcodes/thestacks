defmodule Stacks.BookshelfTelemetryTest do
  @moduledoc """
  Layer 11 (Metrics & Telemetry) for the shelf-browsing read path
  (Issue #112, punch #25).

  `upload_telemetry_test.exs` Suite 11 covers **POST**
  `/api/bookshelves/:name/placements`; the **GET** that every shelf browse
  issues had no telemetry-firing test at all. This module supplies it.

  Two separate things are asserted, because they are wired by two separate
  mechanisms and either can break without the other noticing:

    * Phoenix's native `[:phoenix, :router_dispatch, :stop]` fires with a
      duration and the `StacksWeb.BookshelfController` plug.

    * `[:stacks, :router_dispatch, :stop]` — re-emitted by
      `CoreWeb.Telemetry.handle_router_dispatch_stop/4`
      (`core_web/telemetry.ex:428-433`) — carries `route_group: :bookshelves`.
      The tag comes from the **path-prefix plug**
      `StacksWeb.Plugs.RouteGroup` installed at the endpoint
      (`core_web/endpoint.ex:60`), NOT from a router declaration, so it only
      holds for paths matching the `/api/bookshelves/` prefix rule. This is
      the metadata `scripts/check-slo-gate.sh` groups p95 by.
  """

  # async: false — telemetry handlers are global state.
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  setup do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)

    bookshelf = insert(:bookshelf, user: user, name: "library")
    shelf = insert(:shelf, bookshelf: bookshelf, position: 0)
    book = insert(:book, author: insert(:author))
    insert(:placement, bookshelf: bookshelf, shelf: shelf, book: book)

    {:ok, user: user, token: token, book: book}
  end

  defp auth_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # Attaches to `event_name` but only forwards events whose conn's request_path
  # matches — other async test modules share this global handler namespace, and
  # an unfiltered handler would let a foreign request satisfy assert_receive.
  defp attach_for_path(event_name, path) do
    test_pid = self()

    handler_id =
      "bookshelf-telemetry-#{Enum.join(event_name, "-")}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn name, measurements, metadata, _ ->
        if metadata[:conn] && metadata.conn.request_path == path do
          send(test_pid, {:telemetry, name, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  describe "router_dispatch telemetry for GET /api/bookshelves/:bookshelf_name" do
    test "200 for a populated bookshelf emits router_dispatch with the controller plug", %{
      conn: conn,
      token: token
    } do
      attach_for_path([:phoenix, :router_dispatch, :stop], "/api/bookshelves/library")

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/bookshelves/library")

      assert json_response(conn, 200)["count"] == 1

      assert_receive {:telemetry, [:phoenix, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.plug == StacksWeb.BookshelfController
      assert metadata.plug_opts == :show
    end

    test "200 tags the request into the :bookshelves route group", %{conn: conn, token: token} do
      attach_for_path([:stacks, :router_dispatch, :stop], "/api/bookshelves/library")

      conn
      |> auth_conn(token)
      |> get("/api/bookshelves/library")
      |> json_response(200)

      assert_receive {:telemetry, [:stacks, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)

      assert metadata.route_group == :bookshelves,
             "expected route_group :bookshelves in stacks.router_dispatch.stop metadata, got #{inspect(metadata[:route_group])}"
    end

    test "every valid bookshelf name is tagged :bookshelves", %{token: token} do
      for name <- ~w(antilibrary library wishlist reading_pile looking_for_home) do
        path = "/api/bookshelves/#{name}"
        attach_for_path([:stacks, :router_dispatch, :stop], path)

        build_conn()
        |> auth_conn(token)
        |> get(path)
        |> json_response(200)

        assert_receive {:telemetry, [:stacks, :router_dispatch, :stop], _measurements, metadata},
                       2_000

        assert metadata.route_group == :bookshelves,
               "#{path} was tagged #{inspect(metadata[:route_group])}, not :bookshelves"
      end
    end

    test "404 for an invalid bookshelf name still emits telemetry in the :bookshelves group", %{
      conn: conn,
      token: token
    } do
      attach_for_path([:stacks, :router_dispatch, :stop], "/api/bookshelves/not_a_shelf")

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/bookshelves/not_a_shelf")

      assert json_response(conn, 404)["error"] == "invalid bookshelf name"

      assert_receive {:telemetry, [:stacks, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.route_group == :bookshelves
      assert metadata.plug == StacksWeb.BookshelfController
    end

    test "401 for an unauthenticated browse still emits telemetry in the :bookshelves group", %{
      conn: conn
    } do
      attach_for_path([:stacks, :router_dispatch, :stop], "/api/bookshelves/library")

      conn = get(conn, "/api/bookshelves/library")

      assert conn.status == 401

      assert_receive {:telemetry, [:stacks, :router_dispatch, :stop], measurements, metadata},
                     2_000

      assert is_integer(measurements.duration)
      assert metadata.route_group == :bookshelves
    end
  end
end
