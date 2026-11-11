defmodule StacksWeb.AuthorEventsControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  describe "GET /api/authors/:id/events" do
    test "lists the author's events — dated soonest-first, dateless last, past excluded", %{
      conn: conn
    } do
      author = insert(:author)
      store = insert(:bookstore, name: "The Corner Shop")

      _past =
        insert(:bookstore_event,
          author: author,
          store: store,
          title: "Already happened",
          event_date: DateTime.add(DateTime.utc_now(), -7, :day)
        )

      _later =
        insert(:bookstore_event,
          author: author,
          store: store,
          title: "Later",
          event_date: DateTime.add(DateTime.utc_now(), 30, :day)
        )

      _sooner =
        insert(:bookstore_event,
          author: author,
          store: store,
          title: "Sooner",
          event_date: DateTime.add(DateTime.utc_now(), 7, :day)
        )

      _dateless =
        insert(:bookstore_event,
          author: author,
          store: store,
          title: "See the shop's page",
          event_date: nil
        )

      conn = get(conn, "/api/authors/#{author.id}/events")

      assert %{"events" => events} = json_response(conn, 200)
      assert Enum.map(events, & &1["title"]) == ["Sooner", "Later", "See the shop's page"]
      assert hd(events)["store_name"] == "The Corner Shop"
    end

    test "an unknown author is an empty list, not an error", %{conn: conn} do
      assert %{"events" => []} =
               json_response(get(conn, "/api/authors/#{Ecto.UUID.generate()}/events"), 200)
    end

    test "an id that is not an id says so rather than reporting no events", %{conn: conn} do
      # These two answers used to be identical, which made a caller sending a
      # slug or a name indistinguishable from an author who has no events —
      # permanently, and on the client's own book page.
      assert %{"error" => "invalid_author_id"} =
               json_response(get(conn, "/api/authors/not-a-uuid/events"), 400)
    end

    test "no auth required — the data is the shops' own public pages", %{conn: conn} do
      author = insert(:author)
      assert json_response(get(conn, "/api/authors/#{author.id}/events"), 200)
    end
  end
end
