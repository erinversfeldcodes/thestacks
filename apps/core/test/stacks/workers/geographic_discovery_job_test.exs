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

      # Should enqueue 5 queries based on build_queries/2
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
  end
end
