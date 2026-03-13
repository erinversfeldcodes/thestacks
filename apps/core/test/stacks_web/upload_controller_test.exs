defmodule StacksWeb.UploadControllerTest do
  use CoreWeb.ConnCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Workers.IdentifyBookJob

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)
    authed_conn = put_req_header(conn, "authorization", "Bearer #{token}")
    %{conn: authed_conn, user: user}
  end

  describe "POST /api/upload" do
    test "accepts image upload and enqueues IdentifyBookJob", %{conn: conn, user: user} do
      tmp_path = Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer()}.jpg")
      File.write!(tmp_path, "fake image content")

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "test_book.jpg",
        content_type: "image/jpeg"
      }

      conn = post(conn, "/api/upload", %{"image" => upload})

      assert %{"status" => "accepted", "image_id" => image_id} = json_response(conn, 202)
      assert is_binary(image_id)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => image_id}
      )

      File.rm(tmp_path)
    end

    test "returns 422 when no image provided", %{conn: conn} do
      conn = post(conn, "/api/upload", %{})
      assert %{"error" => "no image provided"} = json_response(conn, 422)
    end

    test "returns 401 without auth token" do
      conn = build_conn()
      conn = post(conn, "/api/upload", %{"image" => "not_a_file"})
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/upload/:image_id/status" do
    test "returns status for an existing image", %{conn: conn} do
      tmp_path = Path.join(System.tmp_dir!(), "status_test_#{System.unique_integer()}.jpg")
      File.write!(tmp_path, "fake image content")

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "test_book.jpg",
        content_type: "image/jpeg"
      }

      %{"image_id" => image_id} =
        conn
        |> post("/api/upload", %{"image" => upload})
        |> json_response(202)

      conn2 = get(conn, "/api/upload/#{image_id}/status")
      assert %{"image_id" => ^image_id, "status" => "pending"} = json_response(conn2, 200)

      File.rm(tmp_path)
    end

    test "returns 404 for unknown image_id", %{conn: conn} do
      conn = get(conn, "/api/upload/#{Ecto.UUID.generate()}/status")
      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 422 for an invalid (non-UUID) image_id", %{conn: conn} do
      conn = get(conn, "/api/upload/not-a-uuid/status")
      assert %{"error" => "invalid image_id"} = json_response(conn, 422)
    end

    test "returns 401 without auth token" do
      conn = build_conn()
      conn = get(conn, "/api/upload/#{Ecto.UUID.generate()}/status")
      assert json_response(conn, 401)
    end

    test "returns book_ids for a resolved image with book_ids populated", %{conn: conn} do
      book = insert(:book)

      image =
        insert(:uploaded_image,
          status: "resolved",
          book_id: book.id,
          book_ids: [book.id]
        )

      conn2 = get(conn, "/api/upload/#{image.id}/status")
      data = json_response(conn2, 200)
      assert data["status"] == "resolved"
      assert book.id in data["book_ids"]
    end

    test "returns book_id as singleton when book_ids is empty", %{conn: conn} do
      book = insert(:book)
      image = insert(:uploaded_image, status: "resolved", book_id: book.id, book_ids: [])

      conn2 = get(conn, "/api/upload/#{image.id}/status")
      data = json_response(conn2, 200)
      assert data["status"] == "resolved"
      assert book.id in data["book_ids"]
    end
  end
end
