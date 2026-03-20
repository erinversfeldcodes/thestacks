defmodule Stacks.Enrichment.ReviewFetcherBehaviour do
  @moduledoc "Behaviour for fetching review data from external sources."

  @callback fetch_reviews(book_id :: String.t()) :: [map()]
end
