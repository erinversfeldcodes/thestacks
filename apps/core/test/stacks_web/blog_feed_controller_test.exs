defmodule StacksWeb.BlogFeedControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  defp public_post(user, attrs) do
    insert(
      :post,
      Keyword.merge(
        [user: user, visibility: "public", syndicated: true, published_at: DateTime.utc_now()],
        attrs
      )
    )
  end

  describe "GET /api/feeds/u/:handle/blog" do
    test "serves Atom 1.0 with canonical entry links, ETag and cache headers", %{conn: conn} do
      user = insert(:user)
      post = public_post(user, title: "On Marginalia")

      conn = get(conn, "/api/feeds/u/#{user.handle}/blog")

      assert response_content_type(conn, :xml) =~ "application/atom+xml"
      assert [etag] = get_resp_header(conn, "etag")
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]

      body = response(conn, 200)
      assert body =~ "On Marginalia"
      assert body =~ "/blog/#{post.id}"

      # 304 on a matching ETag — importer politeness.
      conn2 =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/api/feeds/u/#{user.handle}/blog")

      assert response(conn2, 304) == ""
    end

    test "⛔ a valid OWNER token changes nothing: the platform post stays absent", %{conn: conn} do
      # The absence of :optional_auth is the security control (US-6.2.1 §4):
      # the feed's consumer republishes what it reads, so there must be no
      # authenticated branch at all. This is the guard the story demands.
      user = insert(:user)
      public_post(user, title: "For everyone")

      insert(:post,
        user: user,
        visibility: "platform",
        published_at: DateTime.utc_now(),
        title: "For readers only"
      )

      {:ok, token, _} = Guardian.encode_and_sign(user)

      body =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/feeds/u/#{user.handle}/blog")
        |> response(200)

      assert body =~ "For everyone"
      refute body =~ "For readers only"
    end

    test "a handle with no public posts gets a valid EMPTY feed — 200, never 404", %{conn: conn} do
      # A 404 would make Substack drop the subscription.
      user = insert(:user)

      body = conn |> get("/api/feeds/u/#{user.handle}/blog") |> response(200)
      assert body =~ "<feed"
      refute body =~ "<entry>"
    end

    test "an unknown handle is a 404", %{conn: conn} do
      conn = get(conn, "/api/feeds/u/nobody-here/blog")
      assert json_response(conn, 404)["error"] == "Reader not found"
    end

    test "route ordering: /blog reaches BlogFeedController, not a bookshelf named blog", %{
      conn: conn
    } do
      # ⚠️ Declared before `get "/feeds/u/:handle/:bookshelf_name"` in the
      # router — if that ordering regresses, :bookshelf_name swallows "blog"
      # and this request 404s as "Bookshelf not found". Distinguishable
      # because THIS controller answers an empty feed with 200.
      user = insert(:user)

      conn = get(conn, "/api/feeds/u/#{user.handle}/blog")
      assert response(conn, 200) =~ "Writing on The Stacks"
    end
  end
end
