defmodule StacksWeb.UploadControllerTest do
  # async: false because identify tests swap Application.put_env(:core, :vision_client),
  # which is global state.
  use CoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Accounts.Guardian
  alias Stacks.Books.UploadedImage
  alias Stacks.Storage.Mock, as: StorageMock
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

  describe "POST /api/upload/init" do
    test "returns 201 with image_id + upload_url + expires_in", %{conn: conn} do
      conn = post(conn, "/api/upload/init", %{"content_type" => "image/jpeg"})

      assert %{
               "image_id" => image_id,
               "upload_url" => url,
               "expires_in" => expires_in
             } = json_response(conn, 201)

      assert is_binary(image_id)
      assert String.starts_with?(url, "https://") or String.starts_with?(url, "file://")
      assert is_integer(expires_in) and expires_in > 0
    end

    test "inserts an UploadedImage row with status awaiting_upload", %{conn: conn, user: user} do
      conn = post(conn, "/api/upload/init", %{"content_type" => "image/jpeg"})
      %{"image_id" => image_id} = json_response(conn, 201)

      image = Core.Repo.get!(UploadedImage, image_id)
      assert image.status == "awaiting_upload"
      assert image.user_id == user.id
      assert image.storage_path == "uploads/#{image_id}"
    end

    test "defaults content_type to image/jpeg when absent", %{conn: conn} do
      conn = post(conn, "/api/upload/init", %{})
      assert %{"image_id" => _} = json_response(conn, 201)
    end

    test "returns 401 without auth token" do
      conn = build_conn() |> post("/api/upload/init", %{})
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/upload/:id/commit" do
    setup %{user: user} do
      # Seed an awaiting_upload row as if the user had already called init.
      {:ok, init} = Stacks.Books.init_upload(user.id)
      {:ok, init: init}
    end

    test "returns 202 and enqueues IdentifyBookJob when R2 object exists", %{
      conn: conn,
      user: user,
      init: init
    } do
      # Mock backend: seed bytes at the storage_path so head_image returns {:ok, _}.
      StorageMock.seed("uploads/#{init.image_id}", "fake image bytes")

      conn = post(conn, "/api/upload/#{init.image_id}/commit", %{})

      assert %{"status" => "accepted", "image_id" => image_id} = json_response(conn, 202)
      assert image_id == init.image_id

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => init.image_id}
      )

      # Status must flip from awaiting_upload → pending.
      row = Core.Repo.get!(UploadedImage, init.image_id)
      assert row.status == "pending"
    end

    test "returns 409 not_yet_uploaded when R2 object is missing", %{conn: conn, init: init} do
      # Don't seed — HEAD will 404.
      conn = post(conn, "/api/upload/#{init.image_id}/commit", %{})

      assert %{"error" => "not_yet_uploaded"} = json_response(conn, 409)

      refute_enqueued(worker: IdentifyBookJob, args: %{"image_id" => init.image_id})
    end

    test "returns 404 when image_id does not belong to the caller", %{init: init} do
      # A different user tries to commit the first user's upload.
      other = insert(:user)
      {:ok, other_token, _} = Guardian.encode_and_sign(other)
      other_conn = build_conn() |> put_req_header("authorization", "Bearer #{other_token}")

      StorageMock.seed("uploads/#{init.image_id}", "fake")
      conn = post(other_conn, "/api/upload/#{init.image_id}/commit", %{})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 409 already_committed on repeat commit", %{conn: conn, init: init} do
      StorageMock.seed("uploads/#{init.image_id}", "fake")
      # First commit: succeeds, flips to pending.
      post(conn, "/api/upload/#{init.image_id}/commit", %{})
      # Second commit: row is no longer awaiting_upload.
      conn = post(conn, "/api/upload/#{init.image_id}/commit", %{})
      assert %{"error" => "already_committed"} = json_response(conn, 409)
    end

    test "returns 404 for unknown image_id", %{conn: conn} do
      conn = post(conn, "/api/upload/#{Ecto.UUID.generate()}/commit", %{})
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/upload/identify" do
    test "returns 200 with identified candidates when image_b64 provided", %{conn: conn} do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, Stacks.AI.MockClient)

        conn =
          post(conn, "/api/upload/identify", %{"image_b64" => Base.encode64("fake image bytes")})

        assert %{"status" => "identified", "candidates" => candidates} = json_response(conn, 200)
        assert is_list(candidates)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "returns 200 with identified candidates when image_url provided", %{conn: conn} do
      original = Application.get_env(:core, :vision_client)

      try do
        Application.put_env(:core, :vision_client, Stacks.AI.MockClient)

        conn =
          post(conn, "/api/upload/identify", %{
            "image_url" => "https://example.com/cover.jpg"
          })

        assert %{"status" => "identified", "candidates" => candidates} = json_response(conn, 200)
        assert is_list(candidates)
      after
        Application.put_env(:core, :vision_client, original)
      end
    end

    test "returns 422 when neither image_b64 nor image_url is provided", %{conn: conn} do
      conn = post(conn, "/api/upload/identify", %{})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "returns 401 without auth token" do
      conn = build_conn()
      conn = post(conn, "/api/upload/identify", %{"image_b64" => "abc"})
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/upload/:image_id/stream" do
    test "returns status for a pending image via SSE", %{conn: conn, user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

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

      conn2 = get(build_conn(), "/api/upload/#{image_id}/stream?token=#{token}")
      assert conn2.status == 200
      [content_type | _] = get_resp_header(conn2, "content-type")
      assert String.contains?(content_type, "text/event-stream")

      File.rm(tmp_path)
    end

    test "returns 404 for unknown image_id", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn = get(build_conn(), "/api/upload/#{Ecto.UUID.generate()}/stream?token=#{token}")
      assert json_response(conn, 404)
    end

    test "returns 400 for an invalid (non-UUID) image_id", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      conn = get(build_conn(), "/api/upload/not-a-uuid/stream?token=#{token}")
      assert conn.status in [400, 422]
    end

    test "returns 401 without auth token" do
      conn = get(build_conn(), "/api/upload/#{Ecto.UUID.generate()}/stream")
      assert json_response(conn, 401)
    end

    test "returns 403 when image is owned by a different user", %{user: _user} do
      alias Stacks.Accounts.Guardian

      owner = insert(:user)
      requester = insert(:user)
      {:ok, requester_token, _} = Guardian.encode_and_sign(requester)

      image = insert(:uploaded_image, status: "pending", user_id: owner.id)

      conn = get(build_conn(), "/api/upload/#{image.id}/stream?token=#{requester_token}")
      assert conn.status == 403
    end

    test "returns SSE event body for a resolved image", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      book = insert(:book)

      image =
        insert(:uploaded_image,
          status: "resolved",
          book_id: book.id,
          book_ids: [book.id],
          user_id: user.id
        )

      conn2 = get(build_conn(), "/api/upload/#{image.id}/stream?token=#{token}")
      assert conn2.status == 200
      assert String.contains?(conn2.resp_body, "resolved")
      assert String.contains?(conn2.resp_body, book.id)
    end

    test "returns SSE event body with singleton book_id when book_ids is empty", %{user: user} do
      alias Stacks.Accounts.Guardian
      {:ok, token, _} = Guardian.encode_and_sign(user)

      book = insert(:book)

      image =
        insert(:uploaded_image,
          status: "resolved",
          book_id: book.id,
          book_ids: [],
          user_id: user.id
        )

      conn2 = get(build_conn(), "/api/upload/#{image.id}/stream?token=#{token}")
      assert conn2.status == 200
      assert String.contains?(conn2.resp_body, "resolved")
      assert String.contains?(conn2.resp_body, book.id)
    end
  end
end
