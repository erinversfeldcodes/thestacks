defmodule Stacks.DiscoveryTelemetryTest do
  @moduledoc """
  Firing tests for the 239 discovery/profiles counters: people-search
  outcome (:hit/:zero_result), public-profile resolution (:ok/:not_found
  on both the absent-handle and ghost/block branches), browse-cap hits
  (only when the 221 cap truncated), and handle claims. Metadata is
  bounded atoms only.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian

  defp attach_telemetry(events) do
    test_pid = self()
    ref = make_ref()
    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "people-search telemetry" do
    test "emits :hit with results>0 when the search matches someone", %{conn: conn} do
      attach_telemetry([[:stacks, :search, :people]])
      insert(:user, handle: "adal", display_name: "Ada Lovelace", profile_visibility: "platform")
      viewer = insert(:user)

      conn |> auth_conn(viewer) |> get("/api/search/users", q: "Ada") |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :search, :people],
                      %{count: 1, results: results}, %{outcome: :hit}}

      assert results >= 1
    end

    test "emits :zero_result with results=0 when nothing matches", %{conn: conn} do
      attach_telemetry([[:stacks, :search, :people]])
      viewer = insert(:user)

      conn
      |> auth_conn(viewer)
      |> get("/api/search/users", q: "nobodymatchesthisxyzzy")
      |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :search, :people], %{count: 1, results: 0},
                      %{outcome: :zero_result}}
    end

    test "does NOT put the query string in the metadata (no PII / cardinality)", %{conn: conn} do
      attach_telemetry([[:stacks, :search, :people]])
      viewer = insert(:user)

      conn
      |> auth_conn(viewer)
      |> get("/api/search/users", q: "secret term")
      |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :search, :people], _measurements, metadata}
      assert Map.keys(metadata) == [:outcome]
    end
  end

  describe "public-profile view telemetry" do
    test "emits :ok when a visible profile resolves", %{conn: conn} do
      attach_telemetry([[:stacks, :profile, :view]])
      insert(:user, handle: "visible_one", profile_visibility: "platform")
      viewer = insert(:user)

      conn |> auth_conn(viewer) |> get("/api/u/visible_one") |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :profile, :view], %{count: 1}, %{outcome: :ok}}
    end

    test "emits :not_found when the handle does not exist", %{conn: conn} do
      attach_telemetry([[:stacks, :profile, :view]])
      viewer = insert(:user)

      conn |> auth_conn(viewer) |> get("/api/u/no_such_handle") |> json_response(404)

      assert_receive {:telemetry_event, [:stacks, :profile, :view], %{count: 1},
                      %{outcome: :not_found}}
    end

    test "emits :not_found on the ghost-profile 404 branch", %{conn: conn} do
      attach_telemetry([[:stacks, :profile, :view]])
      insert(:user, handle: "ghost_prof", profile_visibility: "owner")
      viewer = insert(:user)

      conn |> auth_conn(viewer) |> get("/api/u/ghost_prof") |> json_response(404)

      assert_receive {:telemetry_event, [:stacks, :profile, :view], %{count: 1},
                      %{outcome: :not_found}}
    end

    test "does NOT put the handle in the metadata (no PII)", %{conn: conn} do
      attach_telemetry([[:stacks, :profile, :view]])
      insert(:user, handle: "visible_two", profile_visibility: "platform")
      viewer = insert(:user)

      conn |> auth_conn(viewer) |> get("/api/u/visible_two") |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :profile, :view], _measurements, metadata}
      assert Map.keys(metadata) == [:outcome]
    end
  end

  describe "shelf browse-cap telemetry" do
    setup do
      prev = Application.get_env(:core, :public_shelf_cap)
      Application.put_env(:core, :public_shelf_cap, 2)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:core, :public_shelf_cap)
          value -> Application.put_env(:core, :public_shelf_cap, value)
        end
      end)

      :ok
    end

    defp seed_shelf(handle, n) do
      owner = insert(:user, handle: handle, profile_visibility: "platform")
      bookshelf = insert(:bookshelf, user: owner, name: "library", visibility: "platform")
      shelf = insert(:shelf, bookshelf: bookshelf)

      for _ <- 1..n do
        insert(:placement,
          bookshelf: bookshelf,
          shelf: shelf,
          book: insert(:book),
          visibility: "platform"
        )
      end

      handle
    end

    test "emits browse_capped when the visible count EXCEEDS the cap", %{conn: conn} do
      attach_telemetry([[:stacks, :shelf, :browse_capped]])
      seed_shelf("capped_owner", 5)
      viewer = insert(:user)

      conn
      |> auth_conn(viewer)
      |> get("/api/u/capped_owner/bookshelves/library")
      |> json_response(200)

      assert_receive {:telemetry_event, [:stacks, :shelf, :browse_capped], %{count: 1}, %{}}
    end

    test "does NOT emit when the visible count is at or under the cap", %{conn: conn} do
      attach_telemetry([[:stacks, :shelf, :browse_capped]])
      seed_shelf("uncapped_owner", 2)
      viewer = insert(:user)

      conn
      |> auth_conn(viewer)
      |> get("/api/u/uncapped_owner/bookshelves/library")
      |> json_response(200)

      refute_receive {:telemetry_event, [:stacks, :shelf, :browse_capped], _, _}
    end
  end

  describe "handle-claimed telemetry" do
    test "emits when the profile update claims a new handle", %{conn: _conn} do
      attach_telemetry([[:stacks, :handle, :claimed]])
      user = insert(:user, handle: "starterhandle")

      {:ok, _} = Accounts.update_profile(user, %{"handle" => "freshhandle"})

      assert_receive {:telemetry_event, [:stacks, :handle, :claimed], %{count: 1}, %{}}
    end

    test "emits when the profile update changes an existing handle" do
      attach_telemetry([[:stacks, :handle, :claimed]])
      user = insert(:user, handle: "oldhandle")

      {:ok, _} = Accounts.update_profile(user, %{"handle" => "newhandle"})

      assert_receive {:telemetry_event, [:stacks, :handle, :claimed], %{count: 1}, %{}}
    end

    test "does NOT emit when the update leaves the handle unchanged" do
      attach_telemetry([[:stacks, :handle, :claimed]])
      user = insert(:user, handle: "steadyhandle", display_name: "Before")

      {:ok, _} =
        Accounts.update_profile(user, %{"handle" => "steadyhandle", "display_name" => "After"})

      refute_receive {:telemetry_event, [:stacks, :handle, :claimed], _, _}
    end

    test "does NOT emit when no handle key is supplied" do
      attach_telemetry([[:stacks, :handle, :claimed]])
      user = insert(:user, handle: "kepthandle")

      {:ok, _} = Accounts.update_profile(user, %{"display_name" => "Renamed"})

      refute_receive {:telemetry_event, [:stacks, :handle, :claimed], _, _}
    end

    test "does NOT tag the handle value (no PII)" do
      attach_telemetry([[:stacks, :handle, :claimed]])
      user = insert(:user, handle: "pretagged")

      {:ok, _} = Accounts.update_profile(user, %{"handle" => "taggedcheck"})

      assert_receive {:telemetry_event, [:stacks, :handle, :claimed], _measurements, metadata}
      assert metadata == %{}
    end
  end
end
