defmodule StacksWeb.BlogControllerTest do
  @moduledoc "Tests for the BlogController CRUD endpoints."

  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # ---------------------------------------------------------------------------
  # POST /api/blog/posts
  # ---------------------------------------------------------------------------

  describe "POST /api/blog/posts" do
    test "creates a draft post when authenticated", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts", %{title: "New Post", body: "Post body."})

      assert %{"post" => post} = json_response(conn, 201)
      assert post["title"] == "New Post"
      assert post["body"] == "Post body."
      assert post["visibility"] == "owner"
      assert post["published_at"] == nil
    end

    test "returns 422 when visibility exceeds ceiling", %{conn: conn} do
      user = insert(:user, profile_visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts", %{
          title: "Public Post",
          body: "Body.",
          visibility: "platform"
        })

      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "visibility"
    end

    test "returns 422 when required fields are missing", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts", %{})

      assert %{"errors" => _errors} = json_response(conn, 422)
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      conn = post(conn, "/api/blog/posts", %{title: "Test", body: "Body."})
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/blog/posts
  # ---------------------------------------------------------------------------

  describe "GET /api/blog/posts" do
    test "returns published posts for a user (unauthenticated)", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")

      _published =
        insert(:post, user: user, visibility: "platform", published_at: DateTime.utc_now())

      _draft = insert(:post, user: user, visibility: "platform", published_at: nil)

      conn = get(conn, "/api/blog/posts", %{user_id: user.id})

      assert %{"posts" => posts} = json_response(conn, 200)
      assert length(posts) == 1
    end

    test "owner sees all posts including drafts", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")

      _published =
        insert(:post, user: user, visibility: "platform", published_at: DateTime.utc_now())

      _draft = insert(:post, user: user, visibility: "owner", published_at: nil)

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/blog/posts", %{user_id: user.id})

      assert %{"posts" => posts} = json_response(conn, 200)
      assert length(posts) == 2
    end

    test "returns 422 when user_id is missing", %{conn: conn} do
      conn = get(conn, "/api/blog/posts")
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/blog/posts/:id
  # ---------------------------------------------------------------------------

  describe "GET /api/blog/posts/:id" do
    test "shows a published platform-visible post to unauthenticated viewer", %{conn: conn} do
      user = insert(:user, profile_visibility: "platform")

      post =
        insert(:post, user: user, visibility: "platform", published_at: DateTime.utc_now())

      conn = get(conn, "/api/blog/posts/#{post.id}")

      assert %{"post" => returned_post} = json_response(conn, 200)
      assert returned_post["id"] == post.id
    end

    test "returns 404 for owner-only post viewed by non-owner", %{conn: conn} do
      user = insert(:user, profile_visibility: "owner")
      post = insert(:post, user: user, visibility: "owner", published_at: DateTime.utc_now())
      viewer = insert(:user)

      conn =
        conn
        |> auth_conn(viewer)
        |> get("/api/blog/posts/#{post.id}")

      assert json_response(conn, 404)
    end

    test "owner can see their own owner-only post", %{conn: conn} do
      user = insert(:user, profile_visibility: "owner")
      post = insert(:post, user: user, visibility: "owner", published_at: DateTime.utc_now())

      conn =
        conn
        |> auth_conn(user)
        |> get("/api/blog/posts/#{post.id}")

      assert %{"post" => _} = json_response(conn, 200)
    end

    test "returns 404 for nonexistent post", %{conn: conn} do
      conn = get(conn, "/api/blog/posts/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/blog/posts/:id
  # ---------------------------------------------------------------------------

  describe "PUT /api/blog/posts/:id" do
    test "updates a post when called by the owner", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/blog/posts/#{post.id}", %{title: "Updated Title"})

      assert %{"post" => updated} = json_response(conn, 200)
      assert updated["title"] == "Updated Title"
    end

    test "returns 403 when called by a non-owner", %{conn: conn} do
      owner = insert(:user)
      other = insert(:user)
      post = insert(:post, user: owner)

      conn =
        conn
        |> auth_conn(other)
        |> put("/api/blog/posts/#{post.id}", %{title: "Hacked"})

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent post", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/blog/posts/#{Ecto.UUID.generate()}", %{title: "Nope"})

      assert json_response(conn, 404)
    end

    test "returns 422 when visibility exceeds ceiling", %{conn: conn} do
      user = insert(:user, profile_visibility: "owner")
      post = insert(:post, user: user, visibility: "owner")

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/blog/posts/#{post.id}", %{visibility: "platform"})

      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "visibility"
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user)

      conn = put(conn, "/api/blog/posts/#{post.id}", %{title: "Nope"})
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/blog/posts/:id
  # ---------------------------------------------------------------------------

  describe "DELETE /api/blog/posts/:id" do
    test "deletes a post when called by the owner", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/blog/posts/#{post.id}")

      assert %{"deleted" => true} = json_response(conn, 200)
    end

    test "returns 403 when called by a non-owner", %{conn: conn} do
      owner = insert(:user)
      other = insert(:user)
      post = insert(:post, user: owner)

      conn =
        conn
        |> auth_conn(other)
        |> delete("/api/blog/posts/#{post.id}")

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent post", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> delete("/api/blog/posts/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user)

      conn = delete(conn, "/api/blog/posts/#{post.id}")
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/blog/posts/:id/publish
  # ---------------------------------------------------------------------------

  describe "POST /api/blog/posts/:id/publish" do
    test "publishes a draft post", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user, published_at: nil)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts/#{post.id}/publish")

      assert %{"post" => published} = json_response(conn, 200)
      assert published["published_at"] != nil
    end

    test "returns 403 when called by a non-owner", %{conn: conn} do
      owner = insert(:user)
      other = insert(:user)
      post = insert(:post, user: owner, published_at: nil)

      conn =
        conn
        |> auth_conn(other)
        |> post("/api/blog/posts/#{post.id}/publish")

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent post", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts/#{Ecto.UUID.generate()}/publish")

      assert json_response(conn, 404)
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user, published_at: nil)

      conn = post(conn, "/api/blog/posts/#{post.id}/publish")
      assert conn.status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/blog/posts/:post_id/associations/:id/confirm
  # ---------------------------------------------------------------------------

  describe "PUT /api/blog/posts/:post_id/associations/:id/confirm" do
    test "sets visible to true and returns association", %{conn: conn} do
      user = insert(:user)
      blog_post = insert(:post, user: user)
      book = insert(:book)
      {:ok, assoc} = Stacks.Blog.associate_book(blog_post, book.id, %{visible: false})

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/blog/posts/#{blog_post.id}/associations/#{assoc.id}/confirm")

      assert %{"association" => returned} = json_response(conn, 200)
      assert returned["id"] == assoc.id
      assert returned["book_id"] == book.id
      assert returned["visible"] == true
    end

    test "returns 403 when called by non-owner", %{conn: conn} do
      owner = insert(:user)
      other = insert(:user)
      blog_post = insert(:post, user: owner)
      book = insert(:book)
      {:ok, assoc} = Stacks.Blog.associate_book(blog_post, book.id)

      conn =
        conn
        |> auth_conn(other)
        |> put("/api/blog/posts/#{blog_post.id}/associations/#{assoc.id}/confirm")

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent post", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put(
          "/api/blog/posts/#{Ecto.UUID.generate()}/associations/#{Ecto.UUID.generate()}/confirm"
        )

      assert json_response(conn, 404)
    end

    test "returns 404 for nonexistent association", %{conn: conn} do
      user = insert(:user)
      blog_post = insert(:post, user: user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/blog/posts/#{blog_post.id}/associations/#{Ecto.UUID.generate()}/confirm")

      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # PUT /api/blog/posts/:post_id/associations/:id/dismiss
  # ---------------------------------------------------------------------------

  describe "PUT /api/blog/posts/:post_id/associations/:id/dismiss" do
    test "sets visible to false and returns association", %{conn: conn} do
      user = insert(:user)
      blog_post = insert(:post, user: user)
      book = insert(:book)
      {:ok, assoc} = Stacks.Blog.associate_book(blog_post, book.id, %{visible: true})

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/blog/posts/#{blog_post.id}/associations/#{assoc.id}/dismiss")

      assert %{"association" => returned} = json_response(conn, 200)
      assert returned["id"] == assoc.id
      assert returned["book_id"] == book.id
      assert returned["visible"] == false
    end

    test "returns 403 when called by non-owner", %{conn: conn} do
      owner = insert(:user)
      other = insert(:user)
      blog_post = insert(:post, user: owner)
      book = insert(:book)
      {:ok, assoc} = Stacks.Blog.associate_book(blog_post, book.id)

      conn =
        conn
        |> auth_conn(other)
        |> put("/api/blog/posts/#{blog_post.id}/associations/#{assoc.id}/dismiss")

      assert json_response(conn, 403)
    end

    test "returns 404 for nonexistent post", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> auth_conn(user)
        |> put(
          "/api/blog/posts/#{Ecto.UUID.generate()}/associations/#{Ecto.UUID.generate()}/dismiss"
        )

      assert json_response(conn, 404)
    end

    test "returns 404 for nonexistent association", %{conn: conn} do
      user = insert(:user)
      blog_post = insert(:post, user: user)

      conn =
        conn
        |> auth_conn(user)
        |> put("/api/blog/posts/#{blog_post.id}/associations/#{Ecto.UUID.generate()}/dismiss")

      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/blog/posts/:id/chat — writing-assistant (consent-gated, Issue #184)
  # ---------------------------------------------------------------------------

  describe "POST /api/blog/posts/:id/chat" do
    alias Stacks.GDPR.Consent

    test "returns 403 when writing_assistant consent is NOT granted", %{conn: conn} do
      user = insert(:user, consent_writing_assistant: false)
      post = insert(:post, user: user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts/#{post.id}/chat", %{message: "help me write"})

      assert %{"error" => "consent_required", "feature" => "writing_assistant"} =
               json_response(conn, 403)
    end

    test "returns an under_construction response when consent IS granted", %{conn: conn} do
      user = insert(:user)
      {:ok, _} = Consent.grant_consent(user.id, "writing_assistant")
      post = insert(:post, user: user)

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts/#{post.id}/chat", %{message: "help me write"})

      assert %{"status" => "under_construction", "message" => message} = json_response(conn, 200)
      assert message =~ "coming soon"
    end

    test "returns 403 when chatting about another user's post (FF-2 ownership)", %{conn: conn} do
      user = insert(:user)
      {:ok, _} = Consent.grant_consent(user.id, "writing_assistant")
      other_post = insert(:post, user: insert(:user))

      conn =
        conn
        |> auth_conn(user)
        |> post("/api/blog/posts/#{other_post.id}/chat", %{message: "help me write"})

      assert conn.status == 403
    end

    test "returns 401 when unauthenticated", %{conn: conn} do
      user = insert(:user)
      post = insert(:post, user: user)

      conn = post(conn, "/api/blog/posts/#{post.id}/chat", %{message: "hi"})
      assert conn.status == 401
    end
  end
end
