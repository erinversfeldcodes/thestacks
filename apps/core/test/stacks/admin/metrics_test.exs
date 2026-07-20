defmodule Stacks.Admin.MetricsTest do
  @moduledoc """
  Tests for Stacks.Admin.Metrics context — dbt mart queries with fallback.
  """

  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Admin.Metrics

  describe "system_health/0" do
    test "returns fallback data when mart does not exist" do
      result = Metrics.system_health()

      assert is_map(result)
      assert Map.has_key?(result, :db_size_bytes)
      assert Map.has_key?(result, :total_books)
      assert Map.has_key?(result, :total_users)
      assert Map.has_key?(result, :total_placements)
      assert Map.has_key?(result, :generated_at)
      assert is_integer(result.db_size_bytes)
    end
  end

  describe "job_stats/0" do
    test "returns a list (possibly empty) of job stats" do
      result = Metrics.job_stats()
      assert is_list(result)
    end
  end

  describe "data_freshness/0" do
    test "returns fallback map when mart does not exist" do
      result = Metrics.data_freshness()
      assert is_map(result)
    end
  end

  describe "cost_breakdown/0" do
    test "delegates to Stacks.Costs and returns a map" do
      result = Metrics.cost_breakdown()
      assert is_map(result)
      assert Map.has_key?(result, :total_cents)
    end
  end

  describe "gdpr_compliance/0" do
    test "returns fallback data when mart does not exist" do
      result = Metrics.gdpr_compliance()
      assert is_map(result)
      assert Map.has_key?(result, :images_pending_deletion)
      assert Map.has_key?(result, :users_with_consent)
    end
  end

  describe "quality_trends/0" do
    test "returns empty list when mart does not exist" do
      result = Metrics.quality_trends()
      assert is_list(result)
    end

    test "returns a real current snapshot over books with no mart present" do
      # 2 of 3 books have a cover (covers live on editions, not op.books)
      book_a = insert(:book)
      insert(:book_edition, book: book_a, cover_image_url: "https://img/a.jpg")
      insert(:price_snapshot, book: book_a)
      insert(:review_snapshot, book: book_a)

      book_b = insert(:book)
      insert(:book_edition, book: book_b, cover_image_url: "https://img/b.jpg")

      insert(:book)

      assert [snapshot] = Metrics.quality_trends()

      assert snapshot.total_books == 3
      assert snapshot.books_with_covers == 2
      assert snapshot.books_with_prices == 1
      assert snapshot.books_with_reviews == 1
      assert_in_delta snapshot.cover_pct, 66.7, 0.05
      assert Map.has_key?(snapshot, :snapshot_date)
    end
  end

  describe "source_health/0" do
    test "returns a list of source health entries" do
      result = Metrics.source_health()
      assert is_list(result)
    end

    test "emits the decoder-shaped wire map with camelCase keys and ISO8601 timestamps" do
      now = DateTime.utc_now()

      insert(:source_health_check,
        source_name: "healthy-src",
        source_type: "scraper_config",
        status: "healthy",
        consecutive_failures: 0,
        last_success_at: now,
        last_failure_at: nil
      )

      insert(:source_health_check,
        source_name: "broken-src",
        source_type: "review_source",
        status: "broken",
        consecutive_failures: 5,
        last_success_at: nil,
        last_failure_at: now
      )

      results = Metrics.source_health()

      healthy = Enum.find(results, &(&1.name == "healthy-src"))
      broken = Enum.find(results, &(&1.name == "broken-src"))

      # Exactly the #261 getSourceHealth decoder contract — no extra/missing keys.
      assert Enum.sort(Map.keys(healthy)) ==
               [
                 :consecutive_failures,
                 :last_failure_at,
                 :last_success_at,
                 :name,
                 :source_type,
                 :status
               ]

      assert healthy.source_type == "scraper_config"
      assert healthy.status == "healthy"
      assert healthy.consecutive_failures == 0
      # plain strings, NOT proto enums
      assert is_binary(healthy.source_type)
      assert is_binary(healthy.status)
      # last_success_at present -> ISO8601 string; last_failure_at nil -> nil
      assert is_binary(healthy.last_success_at)
      assert healthy.last_success_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert healthy.last_failure_at == nil

      assert broken.status == "broken"
      assert broken.consecutive_failures == 5
      assert broken.last_success_at == nil
      assert is_binary(broken.last_failure_at)
    end
  end

  describe "enrichment_gaps/0" do
    test "returns fallback map when mart does not exist" do
      result = Metrics.enrichment_gaps()
      assert is_map(result)
    end

    test "aggregates real cover/price/review gaps over books with no mart present" do
      # Covers live on editions (op.books has no cover column — Works/Editions model).
      # Book A: an edition carrying a cover + a price + a review -> no gaps
      book_a = insert(:book)
      insert(:book_edition, book: book_a, cover_image_url: "https://img/a.jpg")
      insert(:price_snapshot, book: book_a)
      insert(:review_snapshot, book: book_a)

      # Book B: an edition carrying a cover, no price/review -> missing price + review
      book_b = insert(:book)
      insert(:book_edition, book: book_b, cover_image_url: "https://img/b.jpg")

      # Book C: no edition/cover, no price, no review -> missing all three
      insert(:book)

      result = Metrics.enrichment_gaps()

      assert is_map(result)
      assert result.total_books == 3
      # only Book C has no cover on the book and no edition carrying one
      assert result.missing_cover == 1
      # only Book A has a price / review snapshot
      assert result.missing_prices == 2
      assert result.missing_reviews == 2
    end
  end

  describe "dashboard/0" do
    test "returns aggregated dashboard with all sections" do
      result = Metrics.dashboard()

      assert is_map(result)
      assert Map.has_key?(result, :system_health)
      assert Map.has_key?(result, :job_stats)
      assert Map.has_key?(result, :data_freshness)
      assert Map.has_key?(result, :costs)
      assert Map.has_key?(result, :gdpr)
      assert Map.has_key?(result, :quality_trends)
      assert Map.has_key?(result, :source_health)
      assert Map.has_key?(result, :enrichment_gaps)
      assert Map.has_key?(result, :generated_at)
    end
  end
end
