defmodule StacksWeb.ApiNotFoundTest do
  @moduledoc """
      An API path that does not exist must say so in the API's vocabulary.

      The SPA catch-all serves `index.html` with a 200 for every unrecognised
      path, which is correct for a client-side route and wrong for an API one.
      Before this, a removed endpoint, a typo, or a right-path-wrong-method
      request all came back as `200 text/html` carrying the application shell:
      indistinguishable by status from a working endpoint, impossible for
      `Api.isNotFound` to detect, and a decoder would see HTML rather than an
      error.

      It was found by consequence rather than by inspection. Moving the
      invitation lookup off `GET /api/auth/invite/:code` left that URL answering
      200 — with the live invitation code still in `conn.request_path`, which was
      the whole point of moving it, and now with nothing anomalous in the status
      to notice it by.
  """
  use CoreWeb.ConnCase, async: true

  describe "an unmatched path under /api" do
    test "is 404 JSON, not the application shell", %{conn: conn} do
      conn = get(conn, "/api/no-such-endpoint")

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "answers the same for every method, since a wrong method is also no endpoint", %{
      conn: conn
    } do
      for response <- [
            get(conn, "/api/nope"),
            post(conn, "/api/nope", %{}),
            put(conn, "/api/nope", %{}),
            patch(conn, "/api/nope", %{}),
            delete(conn, "/api/nope")
          ] do
        assert json_response(response, 404) == %{"error" => "not_found"}
      end
    end

    test "the retired invitation lookup no longer answers 200 with the code in the path", %{
      conn: conn
    } do
      # The exact shape that motivated this: the old URL carried the credential
      # in the path, and after the route moved it was being served the app shell.
      assert json_response(get(conn, "/api/auth/invite/STK-ABCD-1234"), 404)
    end

    test "a real endpoint is untouched by the fallback", %{conn: conn} do
      # The fallback sits below every real route, so adding it must not shadow
      # one. A route that exists still answers as itself.
      refute json_response(post(conn, "/api/auth/invite/check", %{"code" => "nope"}), 404) ==
               %{"error" => "not_found"}
    end
  end

  describe "a client-side route" do
    test "still gets the application shell so the SPA can boot", %{conn: conn} do
      conn = get(conn, "/some/deep/spa/route")

      assert response(conn, 200)
      assert response_content_type(conn, :html) =~ "text/html"
    end
  end
end
