defmodule StacksWeb.InternalControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  defp test_signature do
    ts = System.os_time(:second) |> Integer.to_string()
    secret = Application.fetch_env!(:core, :vision_hmac_secret)
    message = "#{ts}.POST./api/internal/vision/associate"
    sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
    "#{ts}.#{sig}"
  end

  describe "POST /api/internal/vision/associate" do
    test "valid HMAC + status confirmed updates cover_image_url", %{conn: conn} do
      edition = insert(:book_edition)

      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "edition_id" => edition.id,
          "cover_url" => "https://example.com/cover.jpg",
          "status" => "confirmed"
        })

      assert json_response(conn, 200)

      updated = Core.Repo.get(Stacks.Books.BookEdition, edition.id)
      assert updated.cover_image_url == "https://example.com/cover.jpg"
    end

    test "valid HMAC + status rejected returns 200 with no DB change", %{conn: conn} do
      edition = insert(:book_edition)
      original_cover = edition.cover_image_url

      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "edition_id" => edition.id,
          "cover_url" => "https://example.com/cover.jpg",
          "status" => "rejected"
        })

      assert json_response(conn, 200)

      unchanged = Core.Repo.get(Stacks.Books.BookEdition, edition.id)
      assert unchanged.cover_image_url == original_cover
    end

    test "missing HMAC header returns 401", %{conn: conn} do
      edition = insert(:book_edition)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "edition_id" => edition.id,
          "cover_url" => "https://example.com/cover.jpg",
          "status" => "confirmed"
        })

      assert json_response(conn, 401)
    end

    test "tampered HMAC header returns 401", %{conn: conn} do
      edition = insert(:book_edition)

      conn =
        conn
        |> put_req_header("x-vision-signature", "1234567890.deadbeefdeadbeef")
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "edition_id" => edition.id,
          "cover_url" => "https://example.com/cover.jpg",
          "status" => "confirmed"
        })

      assert json_response(conn, 401)
    end

    test "valid HMAC + non-existent edition_id returns 200", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "edition_id" => Ecto.UUID.generate(),
          "cover_url" => "https://example.com/cover.jpg",
          "status" => "confirmed"
        })

      assert json_response(conn, 200)
    end
  end
end
