defmodule StacksWeb.CommentControllerTest do
  @moduledoc "Tests for the CommentController endpoints."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp published_post(user) do
    insert(:post, user: user, published_at: DateTime.utc_now())
  end

  # ---------------------------------------------------------------------------
  # POST /api/posts/:post_id/comments
  # ---------------------------------------------------------------------------

  describe "POST /api/posts/:post_id/comments" do
    test "creates a comment (201)", %{conn: conn} do
      user = insert(:user)
      post = published_post(user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/posts/#{post.id}/comments", %{body: "Great post!"})

      assert %{"comment" => comment} = json_response(conn, 201)
      assert comment["body"] == "Great post!"
      assert comment["post_id"] == post.id
    end

    test "returns 404 for unpublished post", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user, published_at: nil)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/posts/#{post.id}/comments", %{body: "Hello"})

      assert json_response(conn, 404)
    end

    test "returns 401 without auth", %{conn: conn} do
      user = insert(:user)
      post = published_post(user)

      conn = post(conn, "/api/posts/#{post.id}/comments", %{body: "Hello"})

      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/comments/:id
  # ---------------------------------------------------------------------------

  describe "DELETE /api/comments/:id" do
    test "comment owner can delete", %{conn: conn} do
      user = insert(:user)
      post = published_post(insert(:user))
      comment = insert(:post_comment, post: post, author: user)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/comments/#{comment.id}")

      assert response(conn, 204) == ""
    end

    test "returns 403 for non-owner", %{conn: conn} do
      other = insert(:user)
      post = published_post(insert(:user))
      comment = insert(:post_comment, post: post, author: insert(:user))

      conn =
        conn
        |> auth_conn(other)
        |> delete("/api/comments/#{comment.id}")

      assert json_response(conn, 403)
    end
  end
end
