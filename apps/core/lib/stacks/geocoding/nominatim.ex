defmodule Stacks.Geocoding.Nominatim do
  @moduledoc """
      Geocoding via Nominatim (OpenStreetMap) — free, keyless, and OSM tags
      match taxonomy. The public instance's policy binds
      us to: a genuine identifying `User-Agent` (`@user_agent` carries project
      + contact URL) and ~1 req/s max — honoured STRUCTURALLY: geocoding runs
      at human-paced approval time and there is deliberately no batch entry
      point (one would need a real throttle). Failures return
      `{:error, reason}` and leave coordinates nil; approval still succeeds.
  """

  @behaviour Stacks.Geocoding

  require Logger

  @fuse :nominatim_fuse

  @user_agent "TheStacks/0.1 (+https://readinginthestacks.com; books@readinginthestacks.com)"

  @impl true
  def geocode(query) do
    case :fuse.ask(@fuse, :sync) do
      :ok -> request(query)
      :blown -> {:error, :circuit_open}
      {:error, :not_found} -> request(query)
    end
  end

  defp request(query) do
    url =
      "#{base_url()}/search?" <>
        URI.encode_query(%{"q" => query, "format" => "json", "limit" => "1"})

    Finch.build(:get, url, [{"user-agent", @user_agent}, {"accept", "application/json"}])
    |> Finch.request(Stacks.Finch, receive_timeout: 10_000, request_timeout: 15_000)
    |> handle(query)
  end

  @doc false
  def handle({:ok, %Finch.Response{status: 200, body: body}}, query) do
    case Jason.decode(body) do
      {:ok, [%{"lat" => lat, "lon" => lon} | _]} ->
        with {latitude, _} <- Float.parse(lat),
             {longitude, _} <- Float.parse(lon) do
          {:ok, %{latitude: latitude, longitude: longitude}}
        else
          _ ->
            Logger.warning("Nominatim: unparseable coordinates for #{inspect(query)}")
            {:error, :unexpected_response}
        end

      {:ok, []} ->
        {:error, :not_found}

      _ ->
        Logger.warning("Nominatim: unexpected response shape for #{inspect(query)}")
        {:error, :unexpected_response}
    end
  end

  def handle({:ok, %Finch.Response{status: 429}}, query) do
    Stacks.CircuitBreakers.melt(@fuse)
    Logger.warning("Nominatim: rate limited on #{inspect(query)} — backing off via the fuse")
    {:error, :rate_limited}
  end

  def handle({:ok, %Finch.Response{status: status}}, query) do
    Stacks.CircuitBreakers.melt(@fuse)
    Logger.warning("Nominatim: HTTP #{status} for #{inspect(query)}")
    {:error, {:http, status}}
  end

  def handle({:error, reason}, query) do
    Stacks.CircuitBreakers.melt(@fuse)
    Logger.warning("Nominatim: request failed for #{inspect(query)}: #{inspect(reason)}")
    {:error, reason}
  end

  defp base_url do
    Application.get_env(:core, :nominatim_base_url, "https://nominatim.openstreetmap.org")
  end
end
