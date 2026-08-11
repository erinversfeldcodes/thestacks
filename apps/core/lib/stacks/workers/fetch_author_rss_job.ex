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
  alias Stacks.Monitoring

  @impl true
  def perform(%Oban.Job{}) do
    authors = Authors.authors_with_rss()
    Logger.info("FetchAuthorRSSJob: polling #{length(authors)} author RSS feeds")

    Enum.each(authors, &poll_author_feed/1)

    :ok
  end

  defp poll_author_feed(author) do
    source_name = "author_rss:#{author.id}"

    case rss_fetcher().fetch_and_parse(author.rss_feed_url) do
      {:ok, feed} ->
        Monitoring.record_success(source_name, "rss_feed")
        entries = extract_entries(feed)
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
        Monitoring.record_failure(source_name, "rss_feed", inspect(reason))

        Logger.warning(
          "FetchAuthorRSSJob: failed to parse feed for author #{author.id} " <>
            "(#{author.rss_feed_url}): #{inspect(reason)}"
        )
    end
  end

  @doc false
  @spec extract_entries(map()) :: [map()]
  def extract_entries(feed) do
    Map.get(feed, :entries, [])
    |> Enum.map(fn entry ->
      %{
        title: Map.get(entry, :title, ""),
        url: Map.get(entry, :url, Map.get(entry, :link, "")),
        published: parse_date(Map.get(entry, :updated, nil)),
        summary: Map.get(entry, :summary, "")
      }
    end)
  end

  @doc false
  @spec filter_recent_entries([map()]) :: [map()]
  def filter_recent_entries(entries) do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

    Enum.filter(entries, fn entry ->
      case entry.published do
        %DateTime{} = dt -> DateTime.compare(dt, cutoff) in [:gt, :eq]
        _ -> false
      end
    end)
  end

  @doc false
  @spec parse_date(nil | String.t() | term()) :: DateTime.t() | nil
  def parse_date(nil), do: nil

  def parse_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _offset} -> dt
      _ -> try_rfc2822(date_string)
    end
  end

  def parse_date(_), do: nil

  @doc false
  @spec try_rfc2822(String.t()) :: DateTime.t() | nil
  def try_rfc2822(date_string) do
    with {:error, _} <- try_timex_format(date_string, "{RFC1123}"),
         {:error, _} <- try_timex_format(date_string, "{RFC1123z}"),
         {:error, _} <- try_timex_format(date_string, "{RFC822}"),
         {:error, _} <- try_timex_format(date_string, "{RFC822z}") do
      nil
    else
      {:ok, dt} -> dt
    end
  end

  @spec try_timex_format(String.t(), String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defp try_timex_format(date_string, format) do
    case Timex.parse(date_string, format) do
      {:ok, %DateTime{} = dt} ->
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

      {:ok, %NaiveDateTime{} = ndt} ->
        {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec serialize_entry(map()) :: map()
  defp serialize_entry(entry) do
    %{
      title: entry.title,
      url: entry.url,
      published: if(entry.published, do: DateTime.to_iso8601(entry.published)),
      summary: String.slice(entry.summary || "", 0, 500)
    }
  end

  @spec rss_fetcher() :: module()
  defp rss_fetcher do
    Application.get_env(:core, :rss_fetcher, Stacks.Enrichment.RssFetcher)
  end
end
