defmodule Stacks.Enrichment.StoreMatcherTest do
  @moduledoc """
      Title matching for the two shops that carry no ISBN on any product.

      A wrong match here does not merely show wrong metadata — it shows a reader a price
      for a different book and links them to buy it. So these tests are mostly about what
      the matcher *refuses*.
  """

  use ExUnit.Case, async: true

  alias Stacks.Enrichment.StoreMatcher

  @listings [
    {"/products/name-of-the-rose-umberto-eco", "The Name of the Rose"},
    {"/products/foucaults-pendulum", "Foucault's Pendulum"},
    {"/products/island-of-the-day-before", "The Island of the Day Before"},
    {"/products/a-study-guide-to-the-name-of-the-rose", "A Study Guide to The Name of the Rose"}
  ]

  describe "matching" do
    test "finds the obvious match" do
      assert {:ok, "/products/name-of-the-rose-umberto-eco", score} =
               StoreMatcher.match_edition(@listings, %{
                 title: "The Name of the Rose",
                 author: "Umberto Eco"
               })

      assert score >= 3.5
    end

    test "prefers the book over a study guide to the book" do
      assert {:ok, path, _} =
               StoreMatcher.match_edition(@listings, %{
                 title: "The Name of the Rose",
                 author: "Umberto Eco"
               })

      refute path =~ "study-guide"
    end

    test "refuses a book the shop does not list" do
      assert :no_match =
               StoreMatcher.match_edition(@listings, %{
                 title: "Wolf Hall",
                 author: "Hilary Mantel"
               })
    end

    test "refuses an empty catalogue" do
      assert :no_match = StoreMatcher.match_edition([], %{title: "The Name of the Rose"})
    end

    test "refuses when two listings are too close to tell apart" do
      ambiguous = [
        {"/products/vol-1", "The Collected Stories"},
        {"/products/vol-2", "The Collected Stories"}
      ]

      assert :no_match =
               StoreMatcher.match_edition(ambiguous, %{title: "The Collected Stories"})
    end

    test "refuses a subtitled listing, which the score alone would accept" do
      assert :no_match =
               StoreMatcher.match_edition(
                 [{"/products/sapiens", "Sapiens: A Brief History of Humankind"}],
                 %{title: "Sapiens"}
               )

      assert {:ok, _, _} =
               StoreMatcher.match_edition(
                 [{"/products/sapiens", "Sapiens: A Brief History of Humankind"}],
                 %{title: "Sapiens"},
                 min_symmetry: 0.0
               )
    end

    test "the margin requirement is what refuses it, not the floor" do
      ambiguous = [
        {"/products/vol-1", "The Collected Stories"},
        {"/products/vol-2", "The Collected Stories"}
      ]

      assert {:ok, _, _} =
               StoreMatcher.match_edition(
                 ambiguous,
                 %{title: "The Collected Stories"},
                 min_margin: 0.0
               )
    end

    test "a partial title alone does not clear the bar" do
      assert :no_match = StoreMatcher.match_edition(@listings, %{title: "The Island"})
    end

    test "accepts string keys, since listings arrive from JSON" do
      assert {:ok, _, _} =
               StoreMatcher.match_edition(@listings, %{
                 "title" => "Foucault's Pendulum",
                 "author" => "Umberto Eco"
               })
    end
  end
end
