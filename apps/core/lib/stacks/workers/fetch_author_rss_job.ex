defmodule Stacks.Workers.FetchAuthorRSSJob do
  @moduledoc """
  Daily Oban cron worker that polls RSS feeds for all authors with an rss_feed_url.

  Fetches each feed, parses entries from the last 24 hours, and emits an
  `enrichment.author_updated` event with the new entries in the payload.

  On feed parse failure: logs a warning and skips the author (does not crash).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Enrichment.Authors
  alias Stacks.Events

  @impl true
  def perform(%Oban.Job{}) do
    authors = Authors.authors_with_rss()
    Logger.info("FetchAuthorRSSJob: polling #{length(authors)} author RSS feeds")

    Enum.each(authors, &poll_author_feed/1)

    :ok
  end

  defp poll_author_feed(author) do
    case fetch_and_parse(author.rss_feed_url) do
      {:ok, entries} ->
        recent = filter_recent_entries(entries)

        if recent != [] do
          Events.emit_safe(%{
            event_type: "enrichment.author_updated",
            aggregate_type: "author",
            aggregate_id: author.id,
            payload: %{
              author_id: author.id,
              new_entries: Enum.map(recent, &serialize_entry/1)
            },
            metadata: %{actor: "system:fetch_author_rss_job"}
          })
        end

      {:error, reason} ->
        Logger.warning(
          "FetchAuthorRSSJob: failed to parse feed for author #{author.id} " <>
            "(#{author.rss_feed_url}): #{inspect(reason)}"
        )
    end
  end

  @doc false
  def fetch_and_parse(feed_url) do
    req = Finch.build(:get, feed_url)

    case Finch.request(req, Stacks.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_feed(body)

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:fetch_error, Exception.message(e)}}
  end

  defp parse_feed(xml_body) do
    case ElixirFeedParser.parse(xml_body) do
      {:ok, feed} ->
        entries =
          Map.get(feed, :entries, [])
          |> Enum.map(fn entry ->
            %{
              title: Map.get(entry, :title, ""),
              url: Map.get(entry, :url, Map.get(entry, :link, "")),
              published: parse_date(Map.get(entry, :updated, nil)),
              summary: Map.get(entry, :summary, "")
            }
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, {:parse_error, reason}}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  defp filter_recent_entries(entries) do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

    Enum.filter(entries, fn entry ->
      case entry.published do
        %DateTime{} = dt -> DateTime.compare(dt, cutoff) in [:gt, :eq]
        _ -> false
      end
    end)
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _offset} -> dt
      _ -> try_rfc2822(date_string)
    end
  end

  defp parse_date(_), do: nil

  defp try_rfc2822(_date_string) do
    # RFC 2822 dates are common in RSS but non-trivial to parse without
    # a dedicated library. For now, return nil for non-ISO-8601 dates.
    # Timex could be used here if more robust parsing is needed.
    nil
  end

  defp serialize_entry(entry) do
    %{
      title: entry.title,
      url: entry.url,
      published: if(entry.published, do: DateTime.to_iso8601(entry.published)),
      summary: String.slice(entry.summary || "", 0, 500)
    }
  end
end
