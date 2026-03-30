defmodule StacksWeb.PartnerInventoryControllerTest do
  use CoreWeb.ConnCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Partners

  setup %{conn: conn} do
    # Create and approve a partner, capture raw key for auth
    {:ok, partner} =
      Partners.register_partner(%{
        name: "Test Bookshop",
        business_type: "bookshop",
        contact_email: "test@bookshop.com"
      })

    admin = insert(:user)
    {:ok, {partner, raw_key}} = Partners.approve_partner(partner.id, admin.id)

    authed_conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> put_req_header("content-type", "application/json")

    # Create a book edition with a known ISBN
    book = insert(:book)
    edition = insert(:book_edition, book: book, isbn: "9780743273565")

    {:ok, conn: authed_conn, partner: partner, edition: edition, raw_key: raw_key}
  end

  describe "POST /api/partner/inventory (sync)" do
    test "syncs known ISBNs and reports unresolved", %{conn: conn, edition: edition} do
      body = %{
        "inventory" => [
          %{
            "isbn" => edition.isbn,
            "price_cents" => 1500,
            "condition" => "good",
            "quantity" => 2
          },
          %{
            "isbn" => "9999999999999",
            "price_cents" => 1000,
            "condition" => "fair",
            "quantity" => 1
          }
        ]
      }

      resp =
        conn
        |> post("/api/partner/inventory", body)
        |> json_response(200)

      assert resp["synced"] == 1
      assert resp["unresolved"] == ["9999999999999"]
    end

    test "strips hyphens from ISBN", %{conn: conn, edition: _edition} do
      hyphenated = "978-0-7432-7356-5"

      body = %{
        "inventory" => [
          %{"isbn" => hyphenated, "price_cents" => 1500, "condition" => "good"}
        ]
      }

      resp =
        conn
        |> post("/api/partner/inventory", body)
        |> json_response(200)

      assert resp["synced"] == 1
      assert resp["unresolved"] == []
    end

    test "upserts on duplicate ISBN (updates price)", %{conn: conn, edition: edition} do
      body1 = %{
        "inventory" => [
          %{"isbn" => edition.isbn, "price_cents" => 1500, "condition" => "good", "quantity" => 1}
        ]
      }

      body2 = %{
        "inventory" => [
          %{
            "isbn" => edition.isbn,
            "price_cents" => 2000,
            "condition" => "like_new",
            "quantity" => 3
          }
        ]
      }

      conn |> post("/api/partner/inventory", body1) |> json_response(200)

      resp =
        conn
        |> post("/api/partner/inventory", body2)
        |> json_response(200)

      assert resp["synced"] == 1

      # Verify updated values via index
      index_resp = conn |> get("/api/partner/inventory") |> json_response(200)
      [item] = index_resp["inventory"]
      assert item["price_cents"] == 2000
      assert item["condition"] == "like_new"
      assert item["quantity"] == 3
    end

    test "returns 422 for missing inventory key", %{conn: conn} do
      resp =
        conn
        |> post("/api/partner/inventory", %{"items" => []})
        |> json_response(422)

      assert resp["error"] =~ "inventory"
    end

    test "returns 401 without auth header", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/partner/inventory", %{"inventory" => []})

      assert json_response(conn, 401)["error"] =~ "Invalid"
    end

    test "emits partner.inventory_synced event", %{conn: conn, partner: partner, edition: edition} do
      body = %{
        "inventory" => [
          %{"isbn" => edition.isbn, "price_cents" => 1500, "condition" => "good", "quantity" => 1}
        ]
      }

      conn |> post("/api/partner/inventory", body) |> json_response(200)

      count =
        Repo.one(
          from(e in "event_log",
            where: e.event_type == "partner.inventory_synced" and e.aggregate_id == ^partner.id,
            select: count(e.id)
          ),
          prefix: "op"
        )

      assert count >= 1
    end
  end

  describe "GET /api/partner/inventory (index)" do
    test "lists partner's own inventory", %{conn: conn, partner: partner, edition: edition} do
      # Sync an item first
      Partners.sync_inventory(partner, [
        %{"isbn" => edition.isbn, "price_cents" => 1500, "condition" => "good", "quantity" => 2}
      ])

      resp = conn |> get("/api/partner/inventory") |> json_response(200)
      assert [item] = resp["inventory"]
      assert item["isbn"] == edition.isbn
      assert item["price_cents"] == 1500
      assert item["condition"] == "good"
      assert item["quantity"] == 2
    end

    test "returns empty list for partner with no inventory", %{conn: conn} do
      resp = conn |> get("/api/partner/inventory") |> json_response(200)
      assert resp["inventory"] == []
    end
  end

  describe "POST /api/partner/inventory/import (CSV)" do
    test "imports valid CSV", %{conn: conn, edition: edition} do
      csv_content = "isbn,price_cents,condition,quantity\n#{edition.isbn},1500,good,2\n"
      upload = csv_upload(csv_content)

      resp =
        conn
        |> delete_req_header("content-type")
        |> post("/api/partner/inventory/import", %{"inventory" => upload})
        |> json_response(200)

      assert resp["synced"] == 1
      assert resp["unresolved"] == []
    end

    test "handles BOM prefix", %{conn: conn, edition: edition} do
      csv_content =
        "\xEF\xBB\xBFisbn,price_cents,condition,quantity\n#{edition.isbn},1500,good,1\n"

      upload = csv_upload(csv_content)

      resp =
        conn
        |> delete_req_header("content-type")
        |> post("/api/partner/inventory/import", %{"inventory" => upload})
        |> json_response(200)

      assert resp["synced"] == 1
    end

    test "returns 422 for too many rows", %{conn: conn} do
      header = "isbn,price_cents,condition,quantity\n"

      rows =
        Enum.map_join(1..10_001, "\n", fn i ->
          "978000000#{String.pad_leading("#{i}", 4, "0")},100,good,1"
        end)

      upload = csv_upload(header <> rows)

      resp =
        conn
        |> delete_req_header("content-type")
        |> post("/api/partner/inventory/import", %{"inventory" => upload})
        |> json_response(422)

      assert resp["error"] == "too many rows"
    end

    test "returns 422 for missing headers", %{conn: conn} do
      csv_content = "wrong,headers\n1234567890123,1500\n"
      upload = csv_upload(csv_content)

      resp =
        conn
        |> delete_req_header("content-type")
        |> post("/api/partner/inventory/import", %{"inventory" => upload})
        |> json_response(422)

      assert resp["error"] =~ "headers"
    end

    test "unknown ISBNs land in unresolved", %{conn: conn} do
      csv_content = "isbn,price_cents,condition,quantity\n9999999999999,1500,good,1\n"
      upload = csv_upload(csv_content)

      resp =
        conn
        |> delete_req_header("content-type")
        |> post("/api/partner/inventory/import", %{"inventory" => upload})
        |> json_response(200)

      assert resp["synced"] == 0
      assert resp["unresolved"] == ["9999999999999"]
    end
  end

  defp csv_upload(content) do
    path =
      Path.join(System.tmp_dir!(), "test_inventory_#{:erlang.unique_integer([:positive])}.csv")

    File.write!(path, content)
    %Plug.Upload{path: path, filename: "inventory.csv", content_type: "text/csv"}
  end
end
