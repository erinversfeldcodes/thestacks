defmodule Stacks.Admin.MetricsTest do
  @moduledoc """
  Tests for Stacks.Admin.Metrics context — dbt mart queries with fallback.
  """

  use Core.DataCase, async: true

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
  end

  describe "source_health/0" do
    test "returns a list of source health entries" do
      result = Metrics.source_health()
      assert is_list(result)
    end
  end

  describe "enrichment_gaps/0" do
    test "returns fallback map when mart does not exist" do
      result = Metrics.enrichment_gaps()
      assert is_map(result)
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
