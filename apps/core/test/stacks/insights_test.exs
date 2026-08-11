defmodule Stacks.InsightsTest do
  @moduledoc """
  Tests for the own-only, ephemeral personal-inference derivations
  (Issue #242, ADR-019 §3a). Load-bearing invariants: own-only scoping,
  no-persistence, derivation correctness, and the de-anon rarity score.
  """

  use CoreWeb.ConnCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Insights

  defp shelve(user, opts \\ []) do
    bs = Keyword.get_lazy(opts, :bookshelf, fn -> insert(:bookshelf, user: user) end)

    book =
      insert(:book,
        subjects: Keyword.get(opts, :subjects, ["fiction"]),
        bisac_codes: Keyword.get(opts, :bisac_codes, ["FIC000000"])
      )

    placement_attrs =
      opts
      |> Keyword.take([:reading_status, :started_at, :finished_at, :placed_at])
      |> Keyword.merge(bookshelf: bs, book: book)

    insert(:placement, placement_attrs)
    book
  end

  describe "interest_profile" do
    test "frequency-counts subjects across shelved books, top-first" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)

      shelve(user, bookshelf: bs, subjects: ["philosophy", "history"])
      shelve(user, bookshelf: bs, subjects: ["philosophy"])
      shelve(user, bookshelf: bs, subjects: ["philosophy", "history"])

      %{interest_profile: %{top_subjects: subjects}} = Insights.personal_inferences(user)

      assert [%{subject: "philosophy", count: 3} | _] = subjects
      assert %{subject: "history", count: 2} in subjects
    end

    test "surfaces top BISAC codes" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)

      shelve(user, bookshelf: bs, bisac_codes: ["OCC000000"])
      shelve(user, bookshelf: bs, bisac_codes: ["OCC000000"])

      %{interest_profile: %{top_bisac: bisac}} = Insights.personal_inferences(user)

      assert %{code: "OCC000000", count: 2} in bisac
    end
  end

  describe "behaviour" do
    test "counts finished/abandoned and computes abandonment rate" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)

      now = DateTime.utc_now()
      earlier = DateTime.add(now, -10, :day)

      shelve(user,
        bookshelf: bs,
        reading_status: "completed",
        started_at: earlier,
        finished_at: now
      )

      shelve(user, bookshelf: bs, reading_status: "completed")
      shelve(user, bookshelf: bs, reading_status: "abandoned")
      shelve(user, bookshelf: bs, reading_status: "to_read")

      %{behaviour: b} = Insights.personal_inferences(user)

      assert b.books_shelved == 4
      assert b.books_finished == 2
      assert b.books_abandoned == 1
      assert b.abandonment_rate == 0.25
      assert b.median_days_to_finish == 10
    end

    test "median_days_to_finish is a whole integer for an even number of finished books" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)

      now = DateTime.utc_now()

      shelve(user,
        bookshelf: bs,
        reading_status: "completed",
        started_at: DateTime.add(now, -10, :day),
        finished_at: now
      )

      shelve(user,
        bookshelf: bs,
        reading_status: "completed",
        started_at: DateTime.add(now, -3, :day),
        finished_at: now
      )

      %{behaviour: b} = Insights.personal_inferences(user)

      assert b.median_days_to_finish == 7
      assert is_integer(b.median_days_to_finish)
    end

    test "zero shelved books gives a zero abandonment rate, no crash" do
      user = insert(:user)
      %{behaviour: b} = Insights.personal_inferences(user)

      assert b.books_shelved == 0
      assert b.abandonment_rate == 0.0
      assert b.median_days_to_finish == nil
      assert b.most_active_hour == nil
    end
  end

  describe "de-anonymisation rarity" do
    test "unique shelf → others_sharing_all == 0, uniqueness \"unique\"" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)
      for _ <- 1..5, do: shelve(user, bookshelf: bs)

      %{deanonymisation: d} = Insights.personal_inferences(user)

      assert d.sample_size == 5
      assert d.others_sharing_all == 0
      assert d.uniqueness == "unique"
      assert is_binary(d.explanation)
    end

    test "one other user sharing all rarest books → others_sharing_all == 1" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)

      books = for _ <- 1..5, do: shelve(user, bookshelf: bs)

      other = insert(:user)
      other_bs = insert(:bookshelf, user: other)
      for book <- books, do: insert(:placement, bookshelf: other_bs, book: book)

      %{deanonymisation: d} = Insights.personal_inferences(user)

      assert d.sample_size == 5
      assert d.others_sharing_all == 1
      assert d.uniqueness == "rare"
    end

    test "fewer than 2 shelved books → graceful insufficient_data shape" do
      user = insert(:user)
      shelve(user)

      %{deanonymisation: d} = Insights.personal_inferences(user)

      assert d.sample_size == 1
      assert d.others_sharing_all == nil
      assert d.uniqueness == "insufficient_data"
      assert is_binary(d.explanation)
    end
  end

  describe "own-only scoping" do
    test "derivations reflect only the given user's data, never another's" do
      alice = insert(:user)
      alice_bs = insert(:bookshelf, user: alice)
      shelve(alice, bookshelf: alice_bs, subjects: ["astronomy"])

      bob = insert(:user)
      bob_bs = insert(:bookshelf, user: bob)
      shelve(bob, bookshelf: bob_bs, subjects: ["gardening"])

      %{interest_profile: %{top_subjects: bob_subjects}} = Insights.personal_inferences(bob)

      subjects = Enum.map(bob_subjects, & &1.subject)
      assert "gardening" in subjects
      refute "astronomy" in subjects
    end
  end

  describe "consent gate + persistence" do
    test "risk_inferences omitted by default, present with reveal_risk" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)
      shelve(user, bookshelf: bs, subjects: ["philosophy"])

      refute Map.has_key?(Insights.personal_inferences(user), :risk_inferences)

      revealed = Insights.personal_inferences(user, reveal_risk: true)
      assert is_list(revealed.risk_inferences)
      assert [%{label: _, could_infer: _, basis: _} | _] = revealed.risk_inferences
    end

    test "computing inferences writes no rows to any table" do
      user = insert(:user)
      bs = insert(:bookshelf, user: user)
      for _ <- 1..3, do: shelve(user, bookshelf: bs)

      counts_before = table_counts()
      _ = Insights.personal_inferences(user, reveal_risk: true)
      counts_after = table_counts()

      assert counts_before == counts_after
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
