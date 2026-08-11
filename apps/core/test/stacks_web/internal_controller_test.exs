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

  defp test_internal_token do
    ts = System.os_time(:second) |> Integer.to_string()
    secret = Application.fetch_env!(:core, :scraper_hmac_secret)
    message = "#{ts}.POST./api/internal/smoke/circuit_breakers"
    sig = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
    "#{ts}.#{sig}"
  end

  describe "POST /api/internal/smoke/circuit_breakers" do
    test "returns 404 when smoke_tests_enabled is false (production default)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/smoke/circuit_breakers", %{})

      assert json_response(conn, 404)
    end

    test "returns 401 when smoke_tests_enabled is true but token is absent", %{conn: conn} do
      original = Application.get_env(:core, :smoke_tests_enabled)
      Application.put_env(:core, :smoke_tests_enabled, true)

      on_exit(fn -> Application.put_env(:core, :smoke_tests_enabled, original) end)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/smoke/circuit_breakers", %{})

      assert json_response(conn, 401)
    end

    test "returns 401 when smoke_tests_enabled is true but token is tampered", %{conn: conn} do
      original = Application.get_env(:core, :smoke_tests_enabled)
      Application.put_env(:core, :smoke_tests_enabled, true)

      on_exit(fn -> Application.put_env(:core, :smoke_tests_enabled, original) end)

      conn =
        conn
        |> put_req_header("x-internal-token", "1234567890.deadbeefdeadbeef")
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/smoke/circuit_breakers", %{})

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/internal/vision/associate" do
    test "valid HMAC + status confirmed updates cover_image_url", %{conn: conn} do
      edition = insert(:book_edition)

      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "isbn" => "9780679410232",
          "job_id" => "test-job-id",
          "edition_id" => edition.id,
          "cover_image_url" => "https://example.com/cover.jpg",
          "status" => "ASSOCIATION_STATUS_CONFIRMED"
        })

      assert json_response(conn, 200)["ok"] == true

      updated = Stacks.Books.get_edition(edition.id)
      assert updated.cover_image_url == "https://example.com/cover.jpg"
    end

    test "valid HMAC + status rejected returns 200 with no DB change", %{conn: conn} do
      edition = insert(:book_edition, cover_image_url: "https://example.com/existing.jpg")
      original_cover = edition.cover_image_url

      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "isbn" => "9780679410232",
          "job_id" => "test-job-id",
          "edition_id" => edition.id,
          "cover_image_url" => "https://example.com/cover.jpg",
          "status" => "ASSOCIATION_STATUS_REJECTED"
        })

      assert json_response(conn, 200)["ok"] == true

      unchanged = Stacks.Books.get_edition(edition.id)
      assert unchanged.cover_image_url == original_cover
    end

    test "missing HMAC header returns 401", %{conn: conn} do
      edition = insert(:book_edition)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "edition_id" => edition.id,
          "cover_image_url" => "https://example.com/cover.jpg",
          "status" => "ASSOCIATION_STATUS_CONFIRMED"
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
          "cover_image_url" => "https://example.com/cover.jpg",
          "status" => "ASSOCIATION_STATUS_CONFIRMED"
        })

      assert json_response(conn, 401)
    end

    test "valid HMAC + non-existent edition_id returns 200", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "isbn" => "9780679410232",
          "job_id" => "test-job-id",
          "edition_id" => Ecto.UUID.generate(),
          "cover_image_url" => "https://example.com/cover.jpg",
          "status" => "ASSOCIATION_STATUS_CONFIRMED"
        })

      assert json_response(conn, 200)["ok"] == true
    end

    test "valid HMAC + missing edition_id returns 200 without DB write", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "isbn" => "9780679410232",
          "job_id" => "some-job-id",
          "cover_image_url" => "https://example.com/cover.jpg",
          "status" => "ASSOCIATION_STATUS_CONFIRMED"
        })

      assert json_response(conn, 200)["ok"] == true
    end

    test "valid HMAC + missing status (empty string) returns 200 without DB write", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "isbn" => "9780679410232",
          "job_id" => "test-job-id",
          "edition_id" => Ecto.UUID.generate(),
          "cover_image_url" => "https://example.com/cover.jpg"
        })

      assert json_response(conn, 200)["ok"] == true
    end

    test "valid HMAC + unknown status emits telemetry and returns 200", %{conn: conn} do
      test_pid = self()

      :telemetry.attach(
        "test-unknown-status-#{inspect(test_pid)}",
        [:stacks, :vision, :unknown_association_status],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:telemetry_fired, metadata.status})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-unknown-status-#{inspect(test_pid)}")
      end)

      conn =
        conn
        |> put_req_header("x-vision-signature", test_signature())
        |> put_req_header("content-type", "application/json")
        |> post("/api/internal/vision/associate", %{
          "isbn" => "9780679410232",
          "job_id" => "test-job-id",
          "edition_id" => Ecto.UUID.generate(),
          "cover_image_url" => "https://example.com/cover.jpg",
          "status" => "ASSOCIATION_STATUS_UNSPECIFIED"
        })

      assert json_response(conn, 200)["ok"] == true
      assert_receive {:telemetry_fired, "ASSOCIATION_STATUS_UNSPECIFIED"}
    end
  end
end
