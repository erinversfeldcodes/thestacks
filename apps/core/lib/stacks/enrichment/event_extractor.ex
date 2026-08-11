defmodule Stacks.Enrichment.EventExtractor do
  @moduledoc """
  The structured tier of bookstore-event extraction (US-2.4.1 / #321 item 4):
  schema.org `Event` objects from JSON-LD `<script type="application/ld+json">`
  blocks — the shape Shopify event apps and most venue plugins actually emit,
  and the one place a page STATES its events rather than styling them.

  Sits in front of the text heuristics: a page that declares its events
  structurally is believed over any regex, because the declaration carries the
  pairing (this title WITH this date) that heading-block scoping can only
  approximate.

  The remaining tiers of the research doc's ladder are deliberately absent:

    * **`.ics`** — neither reachable store links a calendar file today (#307's
      enumeration); building the parser before any store emits the format
      would be machinery in service of nothing. Add it when a store does.
    * **LLM fallback** — extraction-by-model without an eval framework is the
      vision-stack lesson (dfef1333) repeated; deferred with it.
  """

  require Logger

  @script_pattern ~r/<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>(.*?)<\/script>/is

  @doc """
  Every schema.org Event declared in the page's JSON-LD blocks, as attrs maps
  (`:title`, `:event_date`, `:description`, `:location`, `:url` — the same
  vocabulary the persistence path speaks). Pages with no/broken JSON-LD give
  `[]`, never an error: malformed structured data downgrades to the text
  tiers rather than failing the store.
  """
  @spec events(String.t()) :: [map()]
  def events(body) do
    @script_pattern
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.flat_map(fn [json] -> decode_block(json) end)
    |> Enum.flat_map(&unwrap/1)
    |> Enum.filter(&event?/1)
    |> Enum.map(&to_attrs/1)
    |> Enum.reject(&(&1.title in [nil, ""]))
  end

  defp decode_block(json) do
    case Jason.decode(String.trim(json)) do
      {:ok, decoded} -> [decoded]
      {:error, _} -> []
    end
  end

  defp unwrap(%{"@graph" => graph}) when is_list(graph), do: graph
  defp unwrap(list) when is_list(list), do: list
  defp unwrap(%{} = object), do: [object]
  defp unwrap(_), do: []

  defp event?(%{"@type" => type}) when is_binary(type), do: String.ends_with?(type, "Event")

  defp event?(%{"@type" => types}) when is_list(types),
    do: Enum.any?(types, &event?(%{"@type" => &1}))

  defp event?(_), do: false

  defp to_attrs(event) do
    %{
      title: string_or_nil(event["name"]),
      event_date: parse_start(event["startDate"]),
      description: string_or_nil(event["description"]),
      location: location_name(event["location"]),
      url: string_or_nil(event["url"])
    }
  end

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_), do: nil

  defp parse_start(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> parse_bare_date(value)
    end
  end

  defp parse_start(_), do: nil

  defp parse_bare_date(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, dt} <- DateTime.new(date, ~T[00:00:00]) do
      dt
    else
      _ -> nil
    end
  end

  defp location_name(%{"name" => name}) when is_binary(name), do: string_or_nil(name)
  defp location_name(name) when is_binary(name), do: string_or_nil(name)
  defp location_name(_), do: nil
end
