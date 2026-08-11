defmodule Stacks.Enrichment.Authors do
  @moduledoc """
      Enrichment context for author intelligence.

      Queries and updates `Stacks.Books.Author` records with discovered website
      and RSS feed URLs. Does NOT own the Author schema — `Stacks.Books` owns it.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Books
  alias Stacks.Books.Author

  @doc """
      Updates website_url and/or rss_feed_url on an author record.

      Accepts a map with string or atom keys containing `:website_url` and/or
      `:rss_feed_url`.

      Returns `{:ok, author}` or `{:error, changeset}`.
  """
  @spec update_author_sources(Author.t(), map()) ::
          {:ok, Author.t()} | {:error, Ecto.Changeset.t()}
  def update_author_sources(%Author{} = author, attrs) do
    author
    |> Books.author_changeset(attrs)
    |> Repo.update()
  end

  @doc """
      Returns authors missing a website_url or rss_feed_url.

      These are candidates for source discovery via Brave Search.
  """
  @spec authors_without_sources() :: [Author.t()]
  def authors_without_sources do
    Author
    |> where([a], is_nil(a.website_url) or is_nil(a.rss_feed_url))
    |> Repo.all()
  end

  @doc """
      Returns authors that have an rss_feed_url set.

      These are candidates for RSS polling.
  """
  @spec authors_with_rss() :: [Author.t()]
  def authors_with_rss do
    Author
    |> where([a], not is_nil(a.rss_feed_url))
    |> Repo.all()
  end

  @doc """
      Returns an author by ID, or nil if not found.
  """
  @spec get_author(binary()) :: Author.t() | nil
  def get_author(id) do
    Repo.get(Author, id)
  end
end
