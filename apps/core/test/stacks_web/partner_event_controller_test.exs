defmodule StacksWeb.PartnerEventControllerTest do
  use CoreWeb.ConnCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Partners

  setup %{conn: conn} do
    # Create a third space and link it to the partner
    third_space = insert(:third_space)

    {:ok, partner} =
      Partners.register_partner(%{
        name: "Event Bookshop",
        business_type: "bookshop",
        contact_email: "events@bookshop.com"
      })

    admin = insert(:user)
    {:ok, {partner, raw_key}} = Partners.approve_partner(partner.id, admin.id)

    # Link partner to third space
    partner
    |> Ecto.Changeset.change(%{third_space_id: third_space.id})
    |> Core.Repo.update!()

    partner = Core.Repo.get!(Stacks.Partners.Partner, partner.id)

    authed_conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> put_req_header("content-type", "application/json")

    future = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.to_iso8601()
    future_end = DateTime.utc_now() |> DateTime.add(8, :day) |> DateTime.to_iso8601()

    {:ok,
     conn: authed_conn,
     partner: partner,
     third_space: third_space,
     raw_key: raw_key,
     future: future,
     future_end: future_end}
  end

  describe "POST /api/partner/events (create)" do
    test "creates event with valid data", %{conn: conn, future: future, future_end: future_end} do
      body = %{
        "title" => "Book Launch",
        "starts_at" => future,
        "ends_at" => future_end,
        "description" => "A great event",
        "location" => "In-store"
      }

      resp =
        conn
        |> post("/api/partner/events", body)
        |> json_response(201)

      assert resp["event"]["title"] == "Book Launch"
      assert resp["event"]["id"]
    end

    test "returns 422 when starts_at is in the past", %{conn: conn, future_end: future_end} do
      past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_iso8601()

      body = %{
        "title" => "Past Event",
        "starts_at" => past,
        "ends_at" => future_end,
        "description" => "This already happened"
      }

      resp =
        conn
        |> post("/api/partner/events", body)
        |> json_response(422)

      assert resp["error"] =~ "future"
    end

    test "returns 422 when ends_at is before starts_at", %{conn: conn, future: future} do
      earlier = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.to_iso8601()

      body = %{
        "title" => "Bad Event",
        "starts_at" => future,
        "ends_at" => earlier,
        "description" => "Ends before it starts"
      }

      resp =
        conn
        |> post("/api/partner/events", body)
        |> json_response(422)

      assert resp["error"] =~ "ends_at"
    end

    test "returns 401 without auth", %{conn: conn, future: future, future_end: future_end} do
      body = %{
        "title" => "No Auth Event",
        "starts_at" => future,
        "ends_at" => future_end
      }

      resp =
        conn
        |> delete_req_header("authorization")
        |> post("/api/partner/events", body)
        |> json_response(401)

      assert resp["error"] =~ "Invalid"
    end
  end

  describe "GET /api/partner/events (index)" do
    test "lists partner's own events", %{
      conn: conn,
      future: future,
      future_end: future_end
    } do
      body = %{
        "title" => "Listed Event",
        "starts_at" => future,
        "ends_at" => future_end,
        "description" => "Should appear in index"
      }

      conn |> post("/api/partner/events", body) |> json_response(201)

      resp = conn |> get("/api/partner/events") |> json_response(200)
      assert [event] = resp["events"]
      assert event["title"] == "Listed Event"
    end

    test "returns empty list when no events", %{conn: conn} do
      resp = conn |> get("/api/partner/events") |> json_response(200)
      assert resp["events"] == []
    end
  end

  describe "DELETE /api/partner/events/:id" do
    test "deletes partner's own event", %{conn: conn, future: future, future_end: future_end} do
      body = %{
        "title" => "Delete Me",
        "starts_at" => future,
        "ends_at" => future_end
      }

      create_resp = conn |> post("/api/partner/events", body) |> json_response(201)
      event_id = create_resp["event"]["id"]

      resp = conn |> delete("/api/partner/events/#{event_id}") |> json_response(200)
      assert resp["ok"] == true

      # Verify it's gone
      index_resp = conn |> get("/api/partner/events") |> json_response(200)
      assert index_resp["events"] == []
    end

    test "returns 404 for event belonging to another partner", %{conn: conn} do
      # Create another partner's event
      other_space = insert(:third_space)
      other_event = insert(:third_space_event, space: other_space)

      resp =
        conn
        |> delete("/api/partner/events/#{other_event.id}")
        |> json_response(404)

      assert resp["error"] == "not_found"
    end

    test "returns 404 for nonexistent event", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      resp =
        conn
        |> delete("/api/partner/events/#{fake_id}")
        |> json_response(404)

      assert resp["error"] == "not_found"
    end
  end

  describe "event emission" do
    test "emits partner.event_created after create", %{
      conn: conn,
      future: future,
      future_end: future_end
    } do
      body = %{"title" => "Emit Test", "starts_at" => future, "ends_at" => future_end}
      create_resp = conn |> post("/api/partner/events", body) |> json_response(201)
      event_id = create_resp["event"]["id"]

      count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "partner.event_created" and e.aggregate_id == ^event_id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert count >= 1
    end

    test "emits partner.event_deleted after delete", %{
      conn: conn,
      future: future,
      future_end: future_end
    } do
      body = %{"title" => "Delete Emit", "starts_at" => future, "ends_at" => future_end}
      create_resp = conn |> post("/api/partner/events", body) |> json_response(201)
      event_id = create_resp["event"]["id"]

      conn |> delete("/api/partner/events/#{event_id}") |> json_response(200)

      count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "partner.event_deleted" and e.aggregate_id == ^event_id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert count >= 1
    end
  end
end
