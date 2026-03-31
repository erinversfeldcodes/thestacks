defmodule StacksWeb.BookAvailabilityController do
  use CoreWeb, :controller

  alias Stacks.Enrichment

  def show(conn, %{"id" => book_id}) do
    availability = Enrichment.book_availability(book_id)
    render(conn, :show, availability: availability)
  end
end
