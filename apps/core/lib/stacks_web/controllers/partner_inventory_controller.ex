defmodule StacksWeb.PartnerInventoryController do
  @moduledoc "Partner inventory sync endpoints — JSON bulk upsert, CSV import, and listing."

  use CoreWeb, :controller

  alias Stacks.Partners

  NimbleCSV.define(InventoryCSV, separator: ",", escape: "\"")

  @max_csv_rows 10_000

  @doc "POST /api/partner/inventory — JSON bulk upsert."
  def sync(conn, %{"inventory" => items}) when is_list(items) do
    partner = conn.assigns[:current_partner]

    {:ok, result} = Partners.sync_inventory(partner, items)
    json(conn, %{synced: result.synced, unresolved: result.unresolved})
  end

  def sync(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Missing 'inventory' array in request body"})
  end

  @doc "POST /api/partner/inventory/import — CSV upload."
  def import(conn, %{"inventory" => %Plug.Upload{path: path}}) do
    partner = conn.assigns[:current_partner]

    with {:ok, raw} <- File.read(path),
         cleaned = strip_bom(raw),
         {:ok, rows} <- parse_csv(cleaned),
         :ok <- validate_row_count(rows) do
      items =
        Enum.map(rows, fn [isbn, price_cents, condition, quantity] ->
          %{
            "isbn" => String.trim(isbn),
            "price_cents" => parse_int(price_cents),
            "condition" => String.trim(condition),
            "quantity" => parse_int(quantity) || 1
          }
        end)

      {:ok, result} = Partners.sync_inventory(partner, items)
      json(conn, %{synced: result.synced, unresolved: result.unresolved})
    else
      {:error, :too_many_rows} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "too many rows"})

      {:error, :missing_headers} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Missing required CSV headers: isbn,price_cents,condition,quantity"})

      {:error, :malformed_csv} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Malformed CSV data"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "CSV import failed"})
    end
  end

  def import(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Missing 'inventory' file upload"})
  end

  @doc "GET /api/partner/inventory — list partner's own stock."
  def index(conn, _params) do
    partner = conn.assigns[:current_partner]
    items = Partners.list_inventory(partner)

    json(conn, %{
      inventory:
        Enum.map(items, fn item ->
          %{
            id: item.id,
            isbn: item.book_edition && item.book_edition.isbn,
            price_cents: item.price_cents,
            condition: item.condition,
            quantity: item.quantity,
            synced_at: item.synced_at && DateTime.to_iso8601(item.synced_at)
          }
        end)
    })
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(data), do: data

  defp parse_csv(data) do
    lines = String.split(data, ~r/\r?\n/, trim: true)

    case lines do
      [] ->
        {:error, :malformed_csv}

      [header | rest] ->
        headers =
          header
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.downcase/1)

        if headers == ["isbn", "price_cents", "condition", "quantity"] do
          try do
            rows = InventoryCSV.parse_string(Enum.join(rest, "\n"), skip_headers: false)
            {:ok, rows}
          rescue
            _ -> {:error, :malformed_csv}
          end
        else
          {:error, :missing_headers}
        end
    end
  end

  defp validate_row_count(rows) when length(rows) > @max_csv_rows, do: {:error, :too_many_rows}
  defp validate_row_count(_rows), do: :ok

  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
