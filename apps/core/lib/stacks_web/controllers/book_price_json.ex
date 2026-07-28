defmodule StacksWeb.BookPriceJSON do
  def show(%{prices: prices}) do
    %{prices: Enum.map(prices, &render_price/1)}
  end

  defp render_price(price) do
    %{
      # The edition is exposed, not just the work: a shop stocks whichever edition
      # it stocks, and Exclusive Books carries six ISBNs of The Name of the Rose at
      # different prices. Collapsing them would show one arbitrary price as though
      # it were the price of the book.
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
