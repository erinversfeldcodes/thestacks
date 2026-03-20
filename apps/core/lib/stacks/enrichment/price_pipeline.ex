defmodule Stacks.Enrichment.PricePipeline do
  @moduledoc """
  Broadway pipeline for batched persistence of scraped price data.

  Messages are pushed from `TriggerPriceScrapeJob` via `Broadway.push_messages/2`.
  The processor validates each price datum and the batcher bulk-inserts them
  into `op.price_snapshots`.
  """

  use Broadway

  require Logger

  alias Stacks.Enrichment.Prices
  alias Stacks.Events

  @doc false
  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: opts[:name] || __MODULE__,
      producer: [
        module: {Broadway.DummyProducer, []}
      ],
      processors: [
        default: [concurrency: 2]
      ],
      batchers: [
        insert: [batch_size: 50, batch_timeout: 5_000, concurrency: 1]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    case validate_price_data(message.data) do
      {:ok, snapshot_attrs} ->
        message
        |> Broadway.Message.update_data(fn _data -> snapshot_attrs end)
        |> Broadway.Message.put_batcher(:insert)

      {:error, reason} ->
        Broadway.Message.failed(message, reason)
    end
  end

  @impl true
  def handle_batch(:insert, messages, _batch_info, _context) do
    results =
      Enum.map(messages, fn message ->
        case Prices.upsert_snapshot(message.data) do
          {:ok, _snapshot} -> {:ok, message}
          {:error, changeset} -> {:error, message, changeset}
        end
      end)

    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    unless successes == [] do
      first_book_id =
        successes
        |> List.first()
        |> elem(1)
        |> Map.get(:data)
        |> Map.get(:book_id, Ecto.UUID.generate())

      Events.emit_safe(%{
        event_type: "enrichment.prices_scraped",
        aggregate_type: "enrichment",
        aggregate_id: first_book_id,
        payload: %{
          count: Enum.count(successes),
          book_ids: successes |> Enum.map(fn {:ok, msg} -> msg.data[:book_id] end) |> Enum.uniq()
        },
        metadata: %{actor: "system:price_pipeline"}
      })
    end

    failed_messages =
      Enum.flat_map(failures, fn {:error, msg, changeset} ->
        Logger.warning("PricePipeline: failed to upsert snapshot: #{inspect(changeset.errors)}")

        [Broadway.Message.failed(msg, "upsert failed")]
      end)

    success_messages = Enum.map(successes, fn {:ok, msg} -> msg end)
    success_messages ++ failed_messages
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn message ->
      Logger.warning("PricePipeline: message failed: #{inspect(message.status)}")
    end)

    messages
  end

  defp validate_price_data(data) when is_map(data) do
    with {:ok, book_id} <- fetch_field(data, "book_id"),
         {:ok, store_id} <- fetch_field(data, "store_id"),
         {:ok, price_cents} <- fetch_field(data, "price_cents") do
      {:ok,
       %{
         book_id: book_id,
         store_id: store_id,
         price_cents: price_cents,
         currency: Map.get(data, "currency", "ZAR"),
         in_stock: Map.get(data, "in_stock"),
         url: Map.get(data, "url"),
         scraped_at: DateTime.utc_now()
       }}
    end
  end

  defp validate_price_data(_data), do: {:error, :invalid_data}

  defp fetch_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
