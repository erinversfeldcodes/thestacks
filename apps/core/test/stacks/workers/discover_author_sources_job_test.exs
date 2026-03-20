defmodule Stacks.Workers.DiscoverAuthorSourcesJobTest do
  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.Discovery.MockBraveClient
  alias Stacks.Workers.DiscoverAuthorSourcesJob

  describe "perform/1 with author_id" do
    test "discovers website for an author" do
      author = insert(:author)

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "#{author.name} - Official Site",
             url: "https://authorsite.com",
             description: "The official website"
           }
         ]}
      )

      assert :ok =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })

      updated = Core.Repo.get!(Stacks.Books.Author, author.id)
      assert updated.website_url == "https://authorsite.com"
    end

    test "skips social media URLs" do
      author = insert(:author)

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "Author on Twitter",
             url: "https://twitter.com/author",
             description: "Twitter profile"
           },
           %{
             title: "Author Blog",
             url: "https://authorblog.com",
             description: "Personal blog"
           }
         ]}
      )

      assert :ok =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })

      updated = Core.Repo.get!(Stacks.Books.Author, author.id)
      assert updated.website_url == "https://authorblog.com"
    end

    test "returns cancel when author not found" do
      assert {:cancel, "author not found"} =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => Ecto.UUID.generate()
               })
    end

    test "does not overwrite existing website_url" do
      author = insert(:author, website_url: "https://existing.com")

      MockBraveClient.put_response(
        {:ok,
         [
           %{
             title: "New Site",
             url: "https://newsite.com",
             description: "A new site"
           }
         ]}
      )

      assert :ok =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })

      updated = Core.Repo.get!(Stacks.Books.Author, author.id)
      assert updated.website_url == "https://existing.com"
    end

    test "handles search error gracefully" do
      author = insert(:author)
      MockBraveClient.put_response({:error, :api_key_missing})

      assert {:error, :api_key_missing} =
               perform_job(DiscoverAuthorSourcesJob, %{
                 "author_id" => author.id
               })
    end
  end

  describe "perform/1 with batch" do
    test "processes all authors without sources" do
      _author1 = insert(:author, website_url: nil)
      _author2 = insert(:author, website_url: nil)

      MockBraveClient.put_response({:ok, []})

      assert :ok = perform_job(DiscoverAuthorSourcesJob, %{"batch" => true})
    end
  end
end
