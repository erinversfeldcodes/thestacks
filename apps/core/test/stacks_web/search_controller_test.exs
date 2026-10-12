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
    insert(
      :book,
      Keyword.take(attrs, [:title, :author]) ++
        [editions: [build(:primary_book_edition, Keyword.take(attrs, [:isbn]))]]
    )
  end

  defp place(user, book, shelf_name, attrs \\ []) do
    bookshelf = insert(:bookshelf, user: user, name: shelf_name)
    shelf = insert(:shelf, bookshelf: bookshelf)

    insert(
      :placement,
      [book: book, bookshelf: bookshelf, shelf: shelf] ++
        Keyword.take(attrs, [:listing_status, :visibility, :removed_at])
    )
  end

  describe "GET /api/search" do
    test "returns matching books for query", %{conn: conn} do
      insert_book_with_edition(title: "Elixir in Action", isbn: "9781617295027")
      insert_book_with_edition(title: "Programming Phoenix", isbn: "9781680502268")

      conn = get(conn, "/api/search", q: "Elixir")
      response = json_response(conn, 200)

      assert response["query"] == "Elixir"
      titles = Enum.map(response["platform_hits"], & &1["book"]["title"])
      assert "Elixir in Action" in titles
      refute "Programming Phoenix" in titles
    end

    test "returns an empty response for a non-matching query", %{conn: conn} do
      conn = get(conn, "/api/search", q: "ZZZNoMatchZZZ")
      response = json_response(conn, 200)

      assert response["count"] == 0
      assert response["results"] == []
      assert response["collection"] == []
      assert response["platform_hits"] == []
    end

    test "returns 422 when q param missing", %{conn: conn} do
      conn = get(conn, "/api/search")
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "respects a valid limit parameter", %{conn: conn} do
      for i <- 1..5 do
        insert_book_with_edition(title: "Rustica#{i}")
      end

      conn = get(conn, "/api/search", q: "Rustica", limit: "2")
      response = json_response(conn, 200)

      assert length(response["platform_hits"]) <= 2
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

      [hit | _] = response["platform_hits"]
      assert hit["book"]["author"]["name"] == "Ursula K. Le Guin"
    end

    test "answers an anonymous caller instead of walling them out" do
      insert_book_with_edition(title: "Open Stack Primer", isbn: "9780000000255")

      response = build_conn() |> get("/api/search", q: "Open Stack Primer") |> json_response(200)

      titles = Enum.map(response["platform_hits"], & &1["book"]["title"])
      assert "Open Stack Primer" in titles
    end
  end

  describe "GET /api/search — query edge cases" do
    test "tokenises a multi-word query and returns the matching book", %{conn: conn} do
      insert_book_with_edition(title: "Elixir in Action", isbn: "9781617295027")
      insert_book_with_edition(title: "Rust Atomics and Locks", isbn: "9781098119447")

      conn = get(conn, "/api/search", q: "elixir action")
      response = json_response(conn, 200)

      titles = Enum.map(response["platform_hits"], & &1["book"]["title"])
      assert "Elixir in Action" in titles
      refute "Rust Atomics and Locks" in titles
    end

    test "handles a SQL-injection-style query without a 500 and leaves op.books intact",
         %{conn: conn} do
      insert_book_with_edition(title: "Canary Survives", isbn: "9780000000019")

      conn = get(conn, "/api/search", q: "'; DROP TABLE op.books;--")
      response = json_response(conn, 200)

      assert is_list(response["platform_hits"])
      assert %{rows: [[1]]} = Core.Repo.query!("SELECT count(*) FROM op.books")
    end

    test "handles tsquery operator characters without a 500", %{conn: conn} do
      insert_book_with_edition(title: "Boolean Logic Primer", isbn: "9780000000026")

      conn = get(conn, "/api/search", q: "book & (title | !x)")
      response = json_response(conn, 200)

      assert is_list(response["platform_hits"])
    end

    test "handles a very long query gracefully", %{conn: conn} do
      insert_book_with_edition(title: "Brevity", isbn: "9780000000033")

      long_query = String.duplicate("verylongsearchterm ", 200)
      assert String.length(long_query) > 2000

      conn = get(conn, "/api/search", q: long_query)
      response = json_response(conn, 200)

      assert is_list(response["platform_hits"])
    end
  end

  describe "GET /api/search — visibility filtering" do
    test "excludes age_gated books from results for non-age-verified user", %{conn: conn} do
      insert_book_with_edition(title: "Thornfield Chronicles", isbn: "9781234567897")

      insert(:book,
        title: "Thornfield Secrets",
        visibility_tier: "age_gated",
        editions: [build(:primary_book_edition, isbn: "9781234567880")]
      )

      conn = get(conn, "/api/search", q: "Thornfield")
      response = json_response(conn, 200)
      titles = Enum.map(response["platform_hits"], & &1["book"]["title"])

      assert "Thornfield Chronicles" in titles
      refute "Thornfield Secrets" in titles
    end

    test "includes age_gated books in results for age-verified user", %{conn: conn} do
      age_verified_user = insert(:user, age_verified: true)
      {:ok, token, _} = Guardian.encode_and_sign(age_verified_user)
      verified_conn = put_req_header(conn, "authorization", "Bearer #{token}")

      insert_book_with_edition(title: "Gatekeeper Chronicles", isbn: "9781600000089")

      insert(:book,
        title: "Gatekeeper Secrets",
        visibility_tier: "age_gated",
        editions: [build(:primary_book_edition, isbn: "9781600000096")]
      )

      conn = get(verified_conn, "/api/search", q: "Gatekeeper")
      response = json_response(conn, 200)
      titles = Enum.map(response["platform_hits"], & &1["book"]["title"])

      assert "Gatekeeper Chronicles" in titles
      assert "Gatekeeper Secrets" in titles
    end
  end

  describe "GET /api/search — sectioning" do
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
      assert hit["source"] == ""
      assert hit["owner_handle"] == ""
      assert hit["price"] == ""
      assert hit["bookshelf_name"] == "library"
    end

    test "collection hits carry their bookshelf name; platform hits leave it empty",
         %{conn: conn, user: user} do
      mine = insert_book_with_edition(title: "Marginalia Notes", isbn: "9780000000170")
      place(user, mine, "wishlist")

      seller = insert(:user, handle: "note_seller")
      listed = insert_book_with_edition(title: "Marginalia Ledger", isbn: "9780000000187")
      insert(:listing, book: listed, seller: seller, status: "active", price_cents: 5_000)

      response = conn |> get("/api/search", q: "Marginalia") |> json_response(200)

      collection_hit = Enum.find(response["collection"], &(&1["book"]["id"] == mine.id))
      assert collection_hit["bookshelf_name"] == "wishlist"

      platform_hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == listed.id))
      assert platform_hit["source"] == "listed"
      assert platform_hit["bookshelf_name"] == ""
      assert platform_hit["bookshelf_names"] == []
    end

    test "a collection hit names every bookshelf it sits on", %{conn: conn, user: user} do
      book = insert_book_with_edition(title: "Doubly Shelved", isbn: "9780000000194")
      place(user, book, "wishlist")
      place(user, book, "reading_pile")

      response = conn |> get("/api/search", q: "Doubly Shelved") |> json_response(200)

      hits = Enum.filter(response["collection"], &(&1["book"]["id"] == book.id))
      assert length(hits) == 1

      [hit] = hits
      assert Enum.sort(hit["bookshelf_names"]) == ["reading_pile", "wishlist"]
      assert hit["bookshelf_name"] == List.first(hit["bookshelf_names"])
    end

    test "a removed placement is not named among a collection hit's bookshelves",
         %{conn: conn, user: user} do
      book = insert_book_with_edition(title: "Partly Unshelved", isbn: "9780000000200")
      place(user, book, "library")
      place(user, book, "wishlist", removed_at: DateTime.utc_now())

      response = conn |> get("/api/search", q: "Partly Unshelved") |> json_response(200)

      hit = Enum.find(response["collection"], &(&1["book"]["id"] == book.id))
      assert hit["bookshelf_names"] == ["library"]
    end

    test "another user's private library placement leaks no label or provenance",
         %{conn: conn} do
      other = insert(:user)
      book = insert_book_with_edition(title: "Hidden Gardens", isbn: "9780000000101")
      place(other, book, "library", visibility: "owner")

      response = conn |> get("/api/search", q: "Hidden Gardens") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
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

      assert response["results"] == []

      assert response["count"] ==
               length(response["collection"]) + length(response["platform_hits"])

      assert response["count"] == 1

      hit = hd(response["collection"])
      assert Map.has_key?(hit, "book")
      assert Map.has_key?(hit, "source")
      assert Map.has_key?(hit, "owner_handle")
      assert Map.has_key?(hit, "price")
      assert Map.has_key?(hit, "bookshelf_name")
    end
  end

  describe "GET /api/search — anonymous callers" do
    test "an age-restricted book is absent from an anonymous caller's hits" do
      insert_book_with_edition(title: "Cellar Ledger", isbn: "9780000000262")

      insert(:book,
        title: "Cellar Ledger Unabridged",
        visibility_tier: "age_gated",
        editions: [build(:primary_book_edition, isbn: "9780000000279")]
      )

      response = build_conn() |> get("/api/search", q: "Cellar Ledger") |> json_response(200)
      titles = Enum.map(response["platform_hits"], & &1["book"]["title"])

      assert "Cellar Ledger" in titles
      refute "Cellar Ledger Unabridged" in titles
    end

    test "the same query returns a shelf section to its owner and none to an anonymous caller",
         %{conn: conn, user: user} do
      book = insert_book_with_edition(title: "Reading Room Register", isbn: "9780000000286")
      place(user, book, "library")

      owner_response =
        conn |> get("/api/search", q: "Reading Room Register") |> json_response(200)

      anon_response =
        build_conn() |> get("/api/search", q: "Reading Room Register") |> json_response(200)

      assert Enum.map(owner_response["collection"], & &1["book"]["id"]) == [book.id]
      assert anon_response["collection"] == []
      assert book.id in Enum.map(anon_response["platform_hits"], & &1["book"]["id"])
    end

    test "another reader's handle and asking price never reach an anonymous caller",
         %{conn: conn} do
      seller = insert(:user, handle: "quiet_dealer")
      offered = insert_book_with_edition(title: "Foxed Endpapers", isbn: "9780000000293")
      place(seller, offered, "looking_for_home", listing_status: "active")

      listed = insert_book_with_edition(title: "Foxed Marginalia", isbn: "9780000000309")
      insert(:listing, book: listed, seller: seller, status: "active", price_cents: 9_500)

      anon_response = build_conn() |> get("/api/search", q: "Foxed") |> json_response(200)
      hits = anon_response["platform_hits"]
      hit_ids = hits |> Enum.map(& &1["book"]["id"]) |> Enum.sort()

      assert hit_ids == Enum.sort([offered.id, listed.id])
      assert Enum.map(hits, & &1["owner_handle"]) == ["", ""]
      assert Enum.map(hits, & &1["source"]) == ["", ""]
      assert Enum.map(hits, & &1["price"]) == ["", ""]

      authed_response = conn |> get("/api/search", q: "Foxed") |> json_response(200)

      authed_handles =
        authed_response["platform_hits"]
        |> Enum.map(& &1["owner_handle"])
        |> Enum.sort()

      assert authed_handles == ["quiet_dealer", "quiet_dealer"]
    end
  end

  describe "GET /api/search — deep scope" do
    defp insert_description_only_book(title, description, isbn) do
      insert(:book,
        title: title,
        description: description,
        editions: [build(:primary_book_edition, isbn: isbn)]
      )
    end

    test "scope=deep surfaces a description-only match with a highlighted snippet",
         %{conn: conn} do
      book =
        insert_description_only_book(
          "Unrelated Cover",
          "A definitive treatise on interstellar cartography.",
          "9780000000200"
        )

      response = conn |> get("/api/search", q: "cartography", scope: "deep") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
      assert hit, "description-only book should surface under scope=deep"
      assert hit["snippet"] =~ "<mark>cartography</mark>"
    end

    test "default scope (no param) does NOT surface a description-only match", %{conn: conn} do
      book =
        insert_description_only_book(
          "Quiet Spine",
          "A meandering account of deep-sea bioluminescence.",
          "9780000000217"
        )

      response = conn |> get("/api/search", q: "bioluminescence") |> json_response(200)

      platform_ids = Enum.map(response["platform_hits"], & &1["book"]["id"])
      refute book.id in platform_ids
      assert response["results"] == []
    end

    test "a title-only hit under scope=deep carries an empty snippet", %{conn: conn} do
      book =
        insert_description_only_book(
          "Lighthouse Keeper",
          "An unrelated blurb about nothing in particular.",
          "9780000000224"
        )

      response = conn |> get("/api/search", q: "Lighthouse", scope: "deep") |> json_response(200)

      hit = Enum.find(response["platform_hits"], &(&1["book"]["id"] == book.id))
      assert hit, "title match should still surface under deep scope"
      assert hit["snippet"] == ""
    end

    test "deep scope applies to the collection section with a snippet", %{conn: conn, user: user} do
      book =
        insert_description_only_book(
          "My Own Volume",
          "Field notes on alpine mycology and spores.",
          "9780000000231"
        )

      place(user, book, "library")

      response = conn |> get("/api/search", q: "mycology", scope: "deep") |> json_response(200)

      hit = Enum.find(response["collection"], &(&1["book"]["id"] == book.id))
      assert hit, "viewer's own description-matched book should land in collection under deep"
      assert hit["bookshelf_name"] == "library"
      assert hit["snippet"] =~ "<mark>mycology</mark>"

      refute book.id in Enum.map(response["platform_hits"], & &1["book"]["id"])
    end

    test "the SearchHit shape always carries a snippet field (empty by default)", %{conn: conn} do
      insert_book_with_edition(title: "Snippet Shape", isbn: "9780000000248")

      response = conn |> get("/api/search", q: "Snippet Shape") |> json_response(200)

      hit = hd(response["platform_hits"])
      assert Map.has_key?(hit, "snippet")
      assert hit["snippet"] == ""
    end
  end
end
