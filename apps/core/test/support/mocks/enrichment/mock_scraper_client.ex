defmodule Stacks.Enrichment.MockScraperClient do
  @moduledoc """
      Mock scraper client for tests.

      Responses are stored in the process dictionary so each test process is
      isolated and tests can run with `async: true`.

      ## Usage

          MockScraperClient.put_response("9780679410232", "za/exclusive_books", {:ok, %{...}})

      Unmatched calls return `{:ok, %{"price_cents" => 29900,...}}` with default data.
  """

  @behaviour Stacks.Enrichment.ScraperClientBehaviour

  @impl true
  def catalogue_titles(_store_name) do
    Application.get_env(:core, :mock_catalogue_titles, {:ok, []})
  end

  @impl true
  def scrape(isbn, store_name, _product_path), do: scrape(isbn, store_name)

  @doc """
      Mock page fetch, keyed on `{store_name, path}` via `put_page/3`.

      Defaults to a 200 with an empty body rather than a plausible events page: a caller
      that gets fixture HTML it did not ask for cannot tell "parsed nothing" from "fetched
      nothing", and the tests that care about parsing call `parse_events/2` directly.

      Register `{:error, {:robots_blocked, rule}}` to exercise the disallow path — that is
      the branch that must record the block and stop, and it is the one worth testing.
  """
  @impl true
  def fetch_page(store_name, path), do: fetch_page(store_name, path, [])

  @impl true
  def fetch_page(store_name, path, validators) do
    Process.put(
      {__MODULE__, :validators},
      Process.get({__MODULE__, :validators}, []) ++ [{store_name, path, validators}]
    )

    do_fetch_page(store_name, path)
  end

  @doc "Every `fetch_page/3` call's validators, as `{store, path, validators}`, in order."
  def sent_validators, do: Process.get({__MODULE__, :validators}, [])

  defp do_fetch_page(store_name, path) do
    Process.put({__MODULE__, :fetches}, fetches() ++ [{store_name, path}])

    pages = Process.get({__MODULE__, :pages}, [])

    case Enum.find(pages, fn {s, p, _} -> s == store_name and p == path end) do
      {_, _, response} -> response
      nil -> {:ok, %{status: 200, body: "", sitemaps: []}}
    end
  end

  @impl true
  def sitemap_urls(store_name) do
    Process.put({__MODULE__, :sitemap_calls}, sitemap_calls() ++ [store_name])

    case Process.get({__MODULE__, :sitemaps}, [])
         |> Enum.find(fn {s, _} -> s == store_name end) do
      {_, response} ->
        response

      nil ->
        {:ok, %{urls: [], skipped: [], truncated: false, documents_fetched: 0, bytes_read: 0}}
    end
  end

  @doc "Register a `sitemap_urls/1` response for a store."
  def put_sitemap(store_name, response) do
    Process.put(
      {__MODULE__, :sitemaps},
      [{store_name, response} | Process.get({__MODULE__, :sitemaps}, [])]
    )
  end

  @doc "Every `sitemap_urls/1` call made in this process, in order."
  def sitemap_calls, do: Process.get({__MODULE__, :sitemap_calls}, [])

  @doc "Register a `fetch_page/2` response for a specific store + path."
  def put_page(store_name, path, response) do
    pages = Process.get({__MODULE__, :pages}, [])
    Process.put({__MODULE__, :pages}, [{store_name, path, response} | pages])
  end

  @doc "Every `fetch_page/2` call made in this process, as `{store_name, path}`, in order."
  def fetches, do: Process.get({__MODULE__, :fetches}, [])

  @impl true
  def build_index(_store_name) do
    Application.get_env(:core, :mock_index_build_result, {:ok, 0})
  end

  @impl true
  def scrape(isbn, store_name) do
    responses = Process.get(__MODULE__, [])

    case Enum.find(responses, fn {i, s, _} -> i == isbn and s == store_name end) do
      {_, _, response} ->
        response

      nil ->
        {:ok,
         %{
           "isbn" => isbn,
           "store" => store_name,
           "price_cents" => 29_900,
           "currency" => "ZAR",
           "in_stock" => true,
           "url" => "https://example.com/book/#{isbn}",
           "title" => "Test Book",
           "selector_match_rate" => 0.95
         }}
    end
  end

  @doc "Register a response for a specific isbn + store_name pair."
  def put_response(isbn, store_name, response) do
    responses = Process.get(__MODULE__, [])
    Process.put(__MODULE__, [{isbn, store_name, response} | responses])
  end

  @doc "Clear all registered responses for the current process."
  def clear do
    Process.delete({__MODULE__, :validators})
    Process.delete({__MODULE__, :sitemaps})
    Process.delete({__MODULE__, :sitemap_calls})
    Process.delete(__MODULE__)
    Process.delete({__MODULE__, :pages})
    Process.delete({__MODULE__, :fetches})
  end
end
