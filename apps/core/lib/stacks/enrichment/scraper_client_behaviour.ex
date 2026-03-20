defmodule Stacks.Enrichment.ScraperClientBehaviour do
  @moduledoc "Behaviour for the scraper HTTP client — allows test mocking via Application env."

  @callback scrape(isbn :: String.t(), store_name :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
