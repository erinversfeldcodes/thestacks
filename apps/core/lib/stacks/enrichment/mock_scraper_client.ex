defmodule Stacks.Enrichment.MockScraperClient do
  @moduledoc """
  Mock scraper client for tests.

  Responses are stored in the process dictionary so each test process is
  isolated and tests can run with `async: true`.

  ## Usage

      MockScraperClient.put_response("9780679410232", "za/exclusive_books", {:ok, %{...}})

  Unmatched calls return `{:ok, %{"price_cents" => 29900, ...}}` with default data.
  """

  @behaviour Stacks.Enrichment.ScraperClientBehaviour

  @impl true
  def catalogue_titles(_store_name) do
    Application.get_env(:core, :mock_catalogue_titles, {:ok, []})
  end

  @impl true
  def scrape(isbn, store_name, _product_path), do: scrape(isbn, store_name)

  @impl true
  def build_index(_store_name) do
    # Stubbed rather than simulated, and deliberately without touching the Agent: the
    # index is a property of the Rust service's own process, so there is nothing
    # meaningful for a mock to model, and requiring the Agent would make every test
    # that merely triggers a rebuild start one. Tests that care assert on the
    # *decision* to rebuild — the enqueued job — not on a fabricated entry count.
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
    Process.delete(__MODULE__)
  end
end
