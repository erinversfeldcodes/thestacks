defmodule StacksWeb.BookPriceJSON do
  def show(%{prices: prices}) do
    %{prices: Enum.map(prices, &render_price/1)}
  end

  defp render_price(price) do
    %{
      book_edition_id: price.book_edition_id,
      isbn: price.isbn,
      format_label: price.format_label,
      store_id: price.store_id,
      store_name: price.store_name,
      price_cents: price.price_cents,
      currency: price.currency,
      in_stock: price.in_stock,
      url: price.url,
      scraped_at: price.scraped_at
    }
  end
end
