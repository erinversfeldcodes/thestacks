defmodule StacksWeb.BookPriceController do
  use CoreWeb, :controller

  alias Stacks.Enrichment.Prices

  @doc """
  Prices for every edition of a work, across the stores that carry them.

  Reading also refreshes anything stale in the background — see
  `Prices.prices_for_work/2` for why the nightly sweep was the wrong shape.
  """
  def show(conn, %{"id" => book_id}) do
    render(conn, :show, prices: Prices.prices_for_work(book_id))
  end
end
