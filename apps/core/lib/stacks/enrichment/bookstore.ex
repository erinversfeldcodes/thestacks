defmodule Stacks.Enrichment.Bookstore do
  @moduledoc "Schema for op.bookstores table — a bookshop whose prices we scrape."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @type t :: %__MODULE__{}

  schema "bookstores" do
    field :name, :string
    field :website_url, :string
    field :search_template, :string
    field :has_physical, :boolean, default: false
    field :country_code, :string, default: "ZA"
    field :scraper_module, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
