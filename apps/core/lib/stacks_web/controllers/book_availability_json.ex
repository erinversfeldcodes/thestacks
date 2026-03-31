defmodule StacksWeb.BookAvailabilityJSON do
  def show(%{availability: items}) do
    %{availability: Enum.map(items, &render_item/1)}
  end

  defp render_item(item) do
    %{
      partner_name: item.partner,
      isbn: item.edition,
      price_cents: item.price_cents,
      condition: item.condition,
      quantity: item.quantity
    }
  end
end
