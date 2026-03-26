defmodule StacksWeb.InternalControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  # Generates a valid X-Vision-Signature token for the test HMAC secret.
  # Contract under test: "<unix_ts>.<HMAC-SHA256(secret, ts.METHOD.path)>" (hex, lowercase).
  # This must stay in sync with InternalController.verify_hmac/2 — if the signing scheme
  # changes in the controller, this helper must change too (and CI will catch the mismatch
  # via the 401 responses in the auth tests below).
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
      # Proto3 zero value: status field absent from payload → defaults to "" in
      # handle_association/2. validate_callback/1 catches status: "" explicitly.
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
      # Verifies the catch-all is observable — alerts fire when vision rolls back
      # to a pre-enum wire format. See docs/runbooks/vision-service-rollback.md.
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
