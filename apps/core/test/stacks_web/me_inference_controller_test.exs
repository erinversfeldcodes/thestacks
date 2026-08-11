defmodule StacksWeb.MeInferenceControllerTest do
  @moduledoc """
  Tests for GET /api/me/inferences — the authed, own-only personal inference
  view (Issue #242, ADR-019 §3a).

  Load-bearing invariants (the point of the feature):
    * strict own-only authz — no param/route can reach another user's data;
    * ephemeral — a view request persists nothing;
    * consent gate — the risk section is server-gated behind `?reveal_risk=true`.
  """

  use CoreWeb.ConnCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Accounts.Guardian

  defp auth_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp shelve(_user, opts) do
    bs = Keyword.fetch!(opts, :bookshelf)
    book = insert(:book, subjects: Keyword.get(opts, :subjects, ["fiction"]))
    insert(:placement, bookshelf: bs, book: book)
    book
  end

  describe "authentication" do
    test "unauthenticated request → 401", %{conn: conn} do
      conn = get(conn, "/api/me/inferences")
      assert conn.status == 401
    end
  end

  describe "own-only authz" do
    test "returns only the caller's data — no user param can reach another user", %{conn: conn} do
      alice = insert(:user)
      alice_bs = insert(:bookshelf, user: alice)
      shelve(alice, bookshelf: alice_bs, subjects: ["astronomy"])

      bob = insert(:user)
      bob_bs = insert(:bookshelf, user: bob)
      shelve(bob, bookshelf: bob_bs, subjects: ["gardening"])

      body =
        conn
        |> auth_conn(bob)
        |> get("/api/me/inferences", user_id: alice.id)
        |> json_response(200)

      subjects =
        body["interest_profile"]["top_subjects"] |> Enum.map(& &1["subject"])

      assert "gardening" in subjects
      refute "astronomy" in subjects
    end
  end

  describe "no persistence" do
    test "a view request writes no rows to any table", %{conn: conn} do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)
      for _ <- 1..3, do: shelve(user, bookshelf: bs)

      before = table_counts()

      conn
      |> auth_conn(user)
      |> get("/api/me/inferences", reveal_risk: "true")
      |> json_response(200)

      assert before == table_counts()
    end
  end

  describe "consent gate" do
    test "risk_inferences absent by default, present with reveal_risk=true", %{conn: conn} do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)
      shelve(user, bookshelf: bs, subjects: ["philosophy"])

      default =
        conn
        |> auth_conn(user)
        |> get("/api/me/inferences")
        |> json_response(200)

      refute Map.has_key?(default, "risk_inferences")

      revealed =
        build_conn()
        |> auth_conn(user)
        |> get("/api/me/inferences", reveal_risk: "true")
        |> json_response(200)

      assert is_list(revealed["risk_inferences"])
    end
  end

  describe "payload shape" do
    test "includes interest, behaviour, deanonymisation and generated_at", %{conn: conn} do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)
      for _ <- 1..3, do: shelve(user, bookshelf: bs)

      body =
        conn
        |> auth_conn(user)
        |> get("/api/me/inferences")
        |> json_response(200)

      assert %{
               "interest_profile" => %{"top_subjects" => _, "top_bisac" => _},
               "behaviour" => %{"books_shelved" => 3},
               "deanonymisation" => %{"uniqueness" => _, "sample_size" => _},
               "generated_at" => generated_at
             } = body

      assert is_binary(generated_at)
    end
  end

  defp table_counts do
    %{
      placements: Repo.aggregate(from(p in "bookshelf_placements", prefix: "op"), :count),
      bookshelves: Repo.aggregate(from(b in "bookshelves", prefix: "op"), :count),
      history: Repo.aggregate(from(h in "bookshelf_placement_history", prefix: "op"), :count),
      events: Repo.aggregate(from(e in "event_log", prefix: "op"), :count)
    }
  end
end
