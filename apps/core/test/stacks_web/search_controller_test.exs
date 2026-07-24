defmodule StacksWeb.SearchControllerTest do
  use CoreWeb.ConnCase, async: true

  import Stacks.Factory

  alias Stacks.Accounts.Guardian

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, token, _} = Guardian.encode_and_sign(user)
    authed_conn = put_req_header(conn, "authorization", "Bearer #{token}")
    %{conn: authed_conn, user: user}
  end

  defp insert_book_with_edition(attrs) do
    book = insert(:book, Keyword.take(attrs, [:title, :author]))

    insert(
      :book_edition,
      Keyword.merge([book: book, is_primary: true], Keyword.take(attrs, [:isbn]))
    )

    book
  end

  # Places `book` on `user`'s named bookshelf. `attrs` may carry :listing_status
  # (the denormalised marketplace flag) and :visibility. The shelf is built on the
  # same bookshelf so `shelf_id` (NOT NULL) points back at the intended bookshelf.
  defp place(user, book, shelf_name, attrs \\ []) do
    bookshelf = insert(:bookshelf, user: user, name: shelf_name)
    shelf = insert(:shelf, bookshelf: bookshelf)

    insert(
      :placement,
      [book: book, bookshelf: bookshelf, shelf: shelf] ++
        Keyword.take(attrs, [:listing_status, :visibility])
    )
  end

  describe "GET /api/search" do
    test "returns matching books for query", %{conn: conn} do
      insert_book_with_edition(title: "Elixir in Action", isbn: "9781617295027")
      insert_book_with_edition(title: "Programming Phoenix", isbn: "9781680502268")

      conn = get(conn, "/api/search", q: "Elixir")
      response = json_response(conn, 200)

      assert response["query"] == "Elixir"
      titles = Enum.map(response["results"], & &1["title"])
      assert "Elixir in Action" in titles
      refute "Programming Phoenix" in titles
    end

    test "returns empty results for non-matching query", %{conn: conn} do
      conn = get(conn, "/api/search", q: "ZZZNoMatchZZZ")
      response = json_response(conn, 200)

      assert response["count"] == 0
      assert response["results"] == []
    end

    test "returns 422 when q param missing", %{conn: conn} do
      conn = get(conn, "/api/search")
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "respects a valid limit parameter", %{conn: conn} do
      for i <- 1..5 do
        insert_book_with_edition(title: "Rustica#{i}", isbn: "978000000000#{i}")
      end

      conn = get(conn, "/api/search", q: "Rustica", limit: "2")
      response = json_response(conn, 200)

      assert length(response["results"]) <= 2
    end

    test "ignores invalid limit and defaults to 20", %{conn: conn} do
      conn = get(conn, "/api/search", q: "anything", limit: "not_a_number")
      assert json_response(conn, 200)
    end

    test "returns author info when book has an associated author", %{conn: conn} do
      author = insert(:author, name: "Ursula K. Le Guin")
      insert_book_with_edition(title: "Lefthandedness", isbn: "9780441478125", author: author)

      conn = get(conn, "/api/search", q: "Lefthandedness")
      response = json_response(conn, 200)

      [result | _] = response["results"]
      assert result["author"]["name"] == "Ursula K. Le Guin"
    end

    test "returns 401 without authentication" do
      conn = build_conn() |> get("/api/search", q: "test")
      assert json_response(conn, 401)
    end
  end

  # Query edge cases (Issue #115 audit punch #1). These exercise the read path's
  # resilience to real-world input: multi-word tokenisation (the documented
  # `to_tsquery` single-word gotcha — `Books.search_books/2` uses
  # `plainto_tsquery`, which tokenises free text), injection/special-character
  # safety, and pathological length. Each asserts on returned CONTENT + a 200,
  # not merely status, so a regression to `to_tsquery` (which raises a tsquery
  # syntax error on bare multi-word/operator input → 500) is caught here.
  describe "GET /api/search — query edge cases" do
    test "tokenises a multi-word query and returns the matching book", %{conn: conn} do
      insert_book_with_edition(title: "Elixir in Action", isbn: "9781617295027")
      insert_book_with_edition(title: "Rust Atomics and Locks", isbn: "9781098119447")

      conn = get(conn, "/api/search", q: "elixir action")
      response = json_response(conn, 200)

      titles = Enum.map(response["results"], & &1["title"])
      assert "Elixir in Action" in titles
      refute "Rust Atomics and Locks" in titles
    end

    test "handles a SQL-injection-style query without a 500 and leaves op.books intact",
         %{conn: conn} do
      insert_book_with_edition(title: "Canary Survives", isbn: "9780000000019")

      conn = get(conn, "/api/search", q: "'; DROP TABLE op.books;--")
      response = json_response(conn, 200)

      # Query is parameterised + `plainto_tsquery` treats it as plain text — no
      # DDL executes. Sane (list) result shape, and the seeded row still exists.
      assert is_list(response["results"])
      assert %{rows: [[1]]} = Core.Repo.query!("SELECT count(*) FROM op.books")
    end

    test "handles tsquery operator characters without a 500", %{conn: conn} do
      insert_book_with_edition(title: "Boolean Logic Primer", isbn: "9780000000026")

      conn = get(conn, "/api/search", q: "book & (title | !x)")
      response = json_response(conn, 200)

      # `plainto_tsquery` ignores `& | ! ( )` as operators (it would raise under
      # `to_tsquery`); the query degrades to the plain lexemes and 200s.
      assert is_list(response["results"])
    end

    test "handles a very long query gracefully", %{conn: conn} do
      insert_book_with_edition(title: "Brevity", isbn: "9780000000033")

      long_query = String.duplicate("verylongsearchterm ", 200)
      assert String.length(long_query) > 2000

      conn = get(conn, "/api/search", q: long_query)
      response = json_response(conn, 200)

      assert is_list(response["results"])
    end
  end

  # #229 REGRESSION LOCK — search already hides age-gated books from an
  # authenticated-but-unverified viewer via `Stacks.Visibility` (the setup conn's
  # `insert(:user)` defaults `age_verified: false`, i.e. authed-unverified). These
  # two tests lock that behaviour so a future Visibility change can't silently
  # re-expose age-gated books on the search surface (see the catalogue gap #229
  # closed for the SQL-level listing path).
  describe "GET /api/search — visibility filtering" do
    test "excludes age_gated books from results for non-age-verified user", %{conn: conn} do
      insert_book_with_edition(title: "Thornfield Chronicles", isbn: "9781234567897")
      age_gated_book = insert(:book, title: "Thornfield Secrets", visibility_tier: "age_gated")

      insert(:book_edition,
        book: age_gated_book,
        isbn: "9781234567880",
        is_primary: true
      )

      conn = get(conn, "/api/search", q: "Thornfield")
      response = json_response(conn, 200)
      titles = Enum.map(response["results"], & &1["title"])

      assert "Thornfield Chronicles" in titles
      refute "Thornfield Secrets" in titles
    end

    test "includes age_gated books in results for age-verified user", %{conn: conn} do
      age_verified_user = insert(:user, age_verified: true)
      {:ok, token, _} = Guardian.encode_and_sign(age_verified_user)
      verified_conn = put_req_header(conn, "authorization", "Bearer #{token}")

      insert_book_with_edition(title: "Gatekeeper Chronicles", isbn: "9780000000111")

      age_gated_book =
        insert(:book, title: "Gatekeeper Secrets", visibility_tier: "age_gated")

      insert(:book_edition,
        book: age_gated_book,
        isbn: "9780000000222",
        is_primary: true
      )

      conn = get(verified_conn, "/api/search", q: "Gatekeeper")
      response = json_response(conn, 200)
      titles = Enum.map(response["results"], & &1["title"])

      assert "Gatekeeper Chronicles" in titles
      assert "Gatekeeper Secrets" in titles
    end
  end

  # #285 — Platform Discovery Sectioning. The search response is split into
  # "Your Collection" (the viewer's own active-placement title matches) and
  # "On the Platform" (platform-visible book matches), each hit carrying
  # optional discovery-source provenance. Provenance is labelled ONLY when the
  # source is discoverable by design — an always-visible `looking_for_home`
  # placement (`listing_status: "active"`, the `Visibility` marketplace
  # exception) or an active marketplace listing. Ordinary private placements
  # leak NO owner/provenance. `results` (flat list) stays populated for
  # backward compatibility with the pre-migration Elm decoder.
  describe "GET /api/search — sectioning (#285)" do
    test "viewer's own active placement lands in collection, not platform_hits",
         %{conn: conn, user: user} do
      book = insert_book_with_edition(title: "Dune Messiah", isbn: "9780593098233")
      place(user, book, "library")

      response = conn |> get("/api/search", q: "Dune") |> json_response(200)

      collection_titles = Enum.map(response["collection"], & &1["book"]["title"])
      platform_ids = Enum.map(response["platform_hits"], & &1["book"]["id"])

      assert "Dune Messiah" in collection_titles
      refute book.id in platform_ids

      hit = Enum.find(response["collection"], &(&1["book"]["title"] == "Dune Messiah"))
      # Owned by the viewer — never source-labelled.
      assert hit["source"] == ""
      assert hit["owner_handle"] == ""
      assert hit["price"] == ""
    end

    test "another user's private library placement leaks no label or provenance",
         %{conn: conn} do
      other = insert(:user)
      book = insert_book_with_edition(title: "Hidden Gardens", isbn: "9780000000101")
      place(other, book, "library", visibility: "owner")

      response = conn |> get("/api/search", q: "Hidden Gardens") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
      # The public book work is still discoverable, but the private placement's
      # owner and provenance must never surface.
      assert hit, "public book should still be discoverable on the platform"
      assert hit["source"] == ""
      assert hit["owner_handle"] == ""
      refute book.id in Enum.map(response["collection"], & &1["book"]["id"])
    end

    test "another user's active looking_for_home placement is labelled with owner handle",
         %{conn: conn} do
      other = insert(:user, handle: "shelf_owner")
      book = insert_book_with_edition(title: "Wandering Copy", isbn: "9780000000118")
      place(other, book, "looking_for_home", listing_status: "active")

      response = conn |> get("/api/search", q: "Wandering Copy") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
      assert hit["source"] == "looking_for_home"
      assert hit["owner_handle"] == "shelf_owner"
      assert hit["price"] == ""
    end

    test "a looking_for_home placement without an active listing_status is NOT labelled",
         %{conn: conn} do
      other = insert(:user, handle: "idle_owner")
      book = insert_book_with_edition(title: "Idle Advert", isbn: "9780000000163")
      place(other, book, "looking_for_home")

      response = conn |> get("/api/search", q: "Idle Advert") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
      assert hit["source"] == ""
      assert hit["owner_handle"] == ""
    end

    test "an active listing is labelled 'listed' with owner handle and formatted price",
         %{conn: conn} do
      seller = insert(:user, handle: "book_seller")
      book = insert_book_with_edition(title: "Priced Tome", isbn: "9780000000125")
      insert(:listing, book: book, seller: seller, status: "active", price_cents: 12_000)

      response = conn |> get("/api/search", q: "Priced Tome") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
      assert hit["source"] == "listed"
      assert hit["owner_handle"] == "book_seller"
      assert hit["price"] == "R120"
    end

    test "an active listing takes precedence over a looking_for_home label",
         %{conn: conn} do
      seller = insert(:user, handle: "dual_seller")
      book = insert_book_with_edition(title: "Double Signal", isbn: "9780000000132")
      place(seller, book, "looking_for_home", listing_status: "active")
      insert(:listing, book: book, seller: seller, status: "active", price_cents: 8_000)

      response = conn |> get("/api/search", q: "Double Signal") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
      assert hit["source"] == "listed"
      assert hit["price"] == "R80"
    end

    test "collection is empty when the viewer has no matching placement", %{conn: conn} do
      insert_book_with_edition(title: "Unowned Volume", isbn: "9780000000149")

      response = conn |> get("/api/search", q: "Unowned Volume") |> json_response(200)

      assert response["collection"] == []
    end

    test "response carries the sectioned proto shape", %{conn: conn, user: user} do
      book = insert_book_with_edition(title: "Shape Check", isbn: "9780000000156")
      place(user, book, "library")

      response = conn |> get("/api/search", q: "Shape Check") |> json_response(200)

      assert Map.has_key?(response, "results")
      assert Map.has_key?(response, "collection")
      assert Map.has_key?(response, "platform_hits")

      hit = hd(response["collection"])
      assert Map.has_key?(hit, "book")
      assert Map.has_key?(hit, "source")
      assert Map.has_key?(hit, "owner_handle")
      assert Map.has_key?(hit, "price")
    end
  end
end
