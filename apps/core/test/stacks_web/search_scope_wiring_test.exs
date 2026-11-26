defmodule StacksWeb.SearchScopeWiringTest do
  @moduledoc """
      The search endpoint's scope wrapper, asserted through the ENDPOINT rather
      than through the functions it wraps.

      ⛔ WHY THIS EXISTS SEPARATELY FROM `SearchLabelsNeedAScopeTest`. That suite
      proves `Shelving.looking_for_home_labels/1` is refused without a scope —
      a property of the FUNCTION. It does not notice if the controller stops
      calling `Scope.for_viewer/2`, because it never goes through the controller.
      Measured: removing the wrapper from `SearchController` left that suite
      4 tests / 0 failures. A guarantee about a function is not a guarantee about
      the wiring.

      ⚠️ So this case drives `GET /api/search` as the least-privilege role, which
      is the only arrangement in which the wrapper's absence has a symptom. The
      deployed defect it stands for: authenticated search answered **500** for
      every signed-in caller with `42501 insufficient_privilege`, while anonymous
      search returned 200 — the inversion being the tell.

      ⛔ Without `Core.AppRole.as_app_role/2` this passes whatever the controller
      does, because the suite connects as a superuser and a superuser is never
      refused. That is exactly how the defect reached a deployed stack behind a
      green local run.
  """
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Core.AppRole
  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/search establishes a scope before the cross-user label lookups" do
    test "a signed-in search succeeds as the least-privilege role", %{conn: conn} do
      seller = insert(:user)
      book = insert(:book)
      shelf = insert(:bookshelf, user: seller, name: "looking_for_home")
      insert(:placement, bookshelf: shelf, book: book, listing_status: "active")
      viewer = insert(:user)

      body =
        AppRole.as_app_role(fn ->
          conn
          |> auth_conn(viewer)
          |> get("/api/search", q: book.title)
          |> json_response(200)
        end)

      # ⛔ ANTI-VACUITY, asserted on the response SHAPE rather than its contents.
      # A 200 carrying `%{}` would otherwise pass while proving the opposite of
      # the point: the labels are produced INSIDE the scoped block, so an empty
      # body is indistinguishable from a controller that never ran the lookup.
      #
      # ⚖️ Shape, not hits, is the line that avoids coupling to search ranking:
      # echoing the query proves the search path executed, and the two lists
      # prove it assembled a result — neither says WHICH books matched, which is
      # the part that would make this test brittle for no gain.
      assert body["query"] == book.title
      assert is_integer(body["count"])
      assert is_list(body["platform_hits"])
      assert is_list(body["collection"])
    end

    test "an anonymous search succeeds too, so the fix did not trade one caller for the other" do
      # ⚖️ The deployed defect was an INVERSION — anonymous worked and
      # authenticated did not. Asserting only the authenticated side would let a
      # fix that broke the anonymous side look complete.
      book = insert(:book)

      body =
        AppRole.as_app_role(fn ->
          build_conn()
          |> get("/api/search", q: book.title)
          |> json_response(200)
        end)

      assert body["query"] == book.title
      assert is_integer(body["count"])
      assert is_list(body["platform_hits"])
    end
  end
end
