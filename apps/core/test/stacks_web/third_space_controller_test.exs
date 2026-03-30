defmodule StacksWeb.ThirdSpaceControllerTest do
  @moduledoc "Tests for GET /api/third-spaces — public third spaces browse endpoint."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  describe "GET /api/third-spaces" do
    test "returns list of third spaces with upcoming_events", %{conn: conn} do
      space = insert(:third_space, name: "The Book Lounge", city: "Cape Town")
      future_date = DateTime.add(DateTime.utc_now(), 7, :day)
      ends_at = DateTime.add(future_date, 2, :hour)

      insert(:third_space_event,
        space: space,
        title: "Poetry Night",
        event_date: future_date,
        ends_at: ends_at,
        scraped_at: DateTime.utc_now()
      )

      conn = get(conn, "/api/third-spaces")
      response = json_response(conn, 200)

      assert %{"third_spaces" => [third_space]} = response
      assert third_space["name"] == "The Book Lounge"
      assert third_space["city"] == "Cape Town"
      assert third_space["type"] == "cafe"

      assert [event] = third_space["upcoming_events"]
      assert event["title"] == "Poetry Night"
      assert is_binary(event["event_date"])
      assert is_binary(event["ends_at"])
    end

    test "returns empty list when no third spaces exist", %{conn: conn} do
      conn = get(conn, "/api/third-spaces")
      response = json_response(conn, 200)

      assert %{"third_spaces" => []} = response
    end

    test "geo params filter by distance and responds 200", %{conn: conn} do
      insert(:third_space, name: "Cape Town Cafe", city: "Cape Town")

      conn =
        get(conn, "/api/third-spaces", %{
          "lat" => "-33.9249",
          "lng" => "18.4241",
          "radius_km" => "50"
        })

      response = json_response(conn, 200)

      assert is_list(response["third_spaces"])
    end
  end
end
