defmodule Stacks.Workers.GeographicDiscoveryJobTest do
  @moduledoc "Tests for the GeographicDiscoveryJob Oban worker."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  alias Stacks.Workers.GeographicDiscoveryJob
  alias Stacks.Workers.SourceDiscoveryJob

  describe "perform/1" do
    test "enqueues SourceDiscoveryJob for each search query" do
      assert :ok =
               perform_job(GeographicDiscoveryJob, %{
                 "city" => "Cape Town",
                 "country_code" => "ZA"
               })

      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "bookshops in Cape Town"})

      assert_enqueued(
        worker: SourceDiscoveryJob,
        args: %{query: "independent bookstores Cape Town"}
      )

      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "reading groups Cape Town"})

      assert_enqueued(
        worker: SourceDiscoveryJob,
        args: %{query: "book clubs Cape Town South Africa"}
      )

      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "literary events Cape Town"})
    end

    test "includes location in enqueued job args" do
      assert :ok =
               perform_job(GeographicDiscoveryJob, %{
                 "city" => "London",
                 "country_code" => "GB"
               })

      assert_enqueued(
        worker: SourceDiscoveryJob,
        args: %{
          query: "bookshops in London",
          location: %{"city" => "London", "country_code" => "GB"}
        }
      )
    end

    test "maps country code to name in book clubs query" do
      assert :ok =
               perform_job(GeographicDiscoveryJob, %{
                 "city" => "Sydney",
                 "country_code" => "AU"
               })

      assert_enqueued(
        worker: SourceDiscoveryJob,
        args: %{query: "book clubs Sydney Australia"}
      )
    end

    test "uses raw country code when no name mapping exists" do
      assert :ok =
               perform_job(GeographicDiscoveryJob, %{
                 "city" => "Berlin",
                 "country_code" => "DE"
               })

      assert_enqueued(
        worker: SourceDiscoveryJob,
        args: %{query: "book clubs Berlin DE"}
      )
    end

    test "maps all supported country codes correctly" do
      mappings = [
        {"ZA", "South Africa"},
        {"GB", "United Kingdom"},
        {"US", "United States"},
        {"AU", "Australia"},
        {"CA", "Canada"},
        {"NZ", "New Zealand"},
        {"IE", "Ireland"}
      ]

      for {code, country_name} <- mappings do
        assert :ok =
                 perform_job(GeographicDiscoveryJob, %{
                   "city" => "TestCity",
                   "country_code" => code
                 })

        assert_enqueued(
          worker: SourceDiscoveryJob,
          args: %{query: "book clubs TestCity #{country_name}"}
        )
      end
    end

    test "enqueues exactly 5 queries per city" do
      assert :ok =
               perform_job(GeographicDiscoveryJob, %{
                 "city" => "Dublin",
                 "country_code" => "IE"
               })

      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "bookshops in Dublin"})
      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "independent bookstores Dublin"})
      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "reading groups Dublin"})
      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "book clubs Dublin Ireland"})
      assert_enqueued(worker: SourceDiscoveryJob, args: %{query: "literary events Dublin"})
    end

    test "location is included in all enqueued jobs" do
      assert :ok =
               perform_job(GeographicDiscoveryJob, %{
                 "city" => "Toronto",
                 "country_code" => "CA"
               })

      expected_location = %{"city" => "Toronto", "country_code" => "CA"}

      assert_enqueued(
        worker: SourceDiscoveryJob,
        args: %{query: "reading groups Toronto", location: expected_location}
      )

      assert_enqueued(
        worker: SourceDiscoveryJob,
        args: %{query: "literary events Toronto", location: expected_location}
      )
    end
  end
end
