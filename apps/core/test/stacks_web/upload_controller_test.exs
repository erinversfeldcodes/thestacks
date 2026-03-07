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
    test "accepts image_id and enqueues IdentifyBookJob", %{conn: conn, user: user} do
      image_id = Ecto.UUID.generate()
      conn = post(conn, "/api/upload", %{image_id: image_id})

      assert %{"status" => "accepted", "image_id" => ^image_id} = json_response(conn, 202)

      assert_enqueued(
        worker: IdentifyBookJob,
        args: %{"user_id" => user.id, "image_id" => image_id}
      )
    end

    test "returns 422 when no image provided", %{conn: conn} do
      conn = post(conn, "/api/upload", %{})
      assert %{"error" => "no image provided"} = json_response(conn, 422)
    end

    test "returns 401 without auth token" do
      conn = build_conn()
      conn = post(conn, "/api/upload", %{image_id: "test"})
      assert json_response(conn, 401)
    end
  end
end
