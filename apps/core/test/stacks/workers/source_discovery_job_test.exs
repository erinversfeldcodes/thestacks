defmodule Stacks.Workers.SourceDiscoveryJobTest do
  @moduledoc "Tests for the SourceDiscoveryJob Oban worker."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Discovery
  alias Stacks.Discovery.MockBraveClient
  alias Stacks.Discovery.MockSearxngClient
  alias Stacks.Workers.ScoreSourceJob
  alias Stacks.Workers.SourceDiscoveryJob

  describe "perform/1 with query" do
    test "creates new sources from search results" do
      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "Amazing Bookshop",
             url: "https://amazingbooks.com",
             description: "An independent bookshop"
           },
           %{
             title: "Reading Group Cape Town",
             url: "https://readinggroup.com",
             description: "A book club for readers"
           }
         ]}
      )

      assert :ok =
               perform_job(SourceDiscoveryJob, %{
                 "query" => "bookshops in Cape Town"
               })

      assert Discovery.get_source_by_url("https://amazingbooks.com") != nil
      assert Discovery.get_source_by_url("https://readinggroup.com") != nil
    end

    test "enqueues ScoreSourceJob for each new source" do
      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "Test Bookshop",
             url: "https://testscoring.com",
             description: "A bookstore"
           }
         ]}
      )

      assert :ok =
               perform_job(SourceDiscoveryJob, %{
                 "query" => "bookshops"
               })

      assert_enqueued(worker: ScoreSourceJob)
    end

    test "deduplicates against existing sources" do
      insert(:discovered_source, url: "https://existing.com")

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "Existing Source",
             url: "https://existing.com",
             description: "Already known"
           },
           %{
             title: "New Source",
             url: "https://new-source.com",
             description: "Brand new"
           }
         ]}
      )

      assert :ok =
               perform_job(SourceDiscoveryJob, %{
                 "query" => "bookshops"
               })

      # Only the new source should have ScoreSourceJob enqueued
      new_source = Discovery.get_source_by_url("https://new-source.com")
      assert new_source != nil
      assert new_source.status == "pending_review"
    end

    test "falls back to SearXNG when Brave budget exhausted" do
      MockBraveClient.put_response({:error, :daily_budget_exhausted})

      MockSearxngClient.put_response(
        {:ok,
         [
           %{
             title: "Fallback Bookshop",
             url: "https://fallback.com",
             description: "Found via SearXNG"
           }
         ]}
      )

      assert :ok =
               perform_job(SourceDiscoveryJob, %{
                 "query" => "bookshops"
               })

      assert Discovery.get_source_by_url("https://fallback.com") != nil
    end

    test "returns error when both search clients fail" do
      MockBraveClient.put_response({:error, :api_key_missing})
      MockSearxngClient.put_response({:error, :url_not_configured})

      assert {:error, :url_not_configured} =
               perform_job(SourceDiscoveryJob, %{
                 "query" => "bookshops"
               })
    end

    test "includes location in discovered_via when provided" do
      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "Local Bookshop",
             url: "https://localbookshop.com",
             description: "A bookshop"
           }
         ]}
      )

      assert :ok =
               perform_job(SourceDiscoveryJob, %{
                 "query" => "bookshops in Cape Town",
                 "location" => %{"city" => "Cape Town", "country_code" => "ZA"}
               })

      source = Discovery.get_source_by_url("https://localbookshop.com")
      assert source.discovered_via =~ "Cape Town"
      assert source.discovered_via =~ "ZA"
    end

    test "infers type from search result content" do
      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "Local Book Club",
             url: "https://bookclub.com",
             description: "A reading group for the community"
           }
         ]}
      )

      assert :ok =
               perform_job(SourceDiscoveryJob, %{
                 "query" => "reading groups"
               })

      source = Discovery.get_source_by_url("https://bookclub.com")
      assert source.type == "community"
    end
  end
end
