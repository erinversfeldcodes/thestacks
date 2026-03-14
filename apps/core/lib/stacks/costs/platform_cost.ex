defmodule Stacks.Costs.PlatformCost do
  @moduledoc "Schema for op.platform_costs table — infrastructure cost line items."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @valid_categories ~w(hosting compute database domain)

  schema "platform_costs" do
    field :category, :string
    field :service, :string
    field :description, :string
    field :amount_cents, :integer
    field :currency, :string, default: "USD"
    field :period_start, :utc_datetime_usec
    field :period_end, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Changeset for creating or updating a platform cost line item."
  def changeset(cost, attrs) do
    cost
    |> cast(attrs, [
      :category,
      :service,
      :description,
      :amount_cents,
      :currency,
      :period_start,
      :period_end
    ])
    |> validate_required([
      :category,
      :service,
      :amount_cents,
      :currency,
      :period_start,
      :period_end
    ])
    |> validate_inclusion(:category, @valid_categories)
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:service, :period_start, :period_end])
  end
end
