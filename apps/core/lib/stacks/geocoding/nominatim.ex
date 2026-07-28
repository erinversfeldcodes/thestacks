defmodule Stacks.Geocoding.Nominatim do
  @moduledoc """
  Geocoding via Nominatim (OpenStreetMap).

  Chosen because it is free, needs no key, and US-3.1.1's category taxonomy is already
  OSM tags — so the place vocabulary matches the one the story specifies rather than
  needing a translation layer.

  ## Honouring the usage policy

  Nominatim's public instance is a donated service with a published policy, and the two
  requirements that bind us are:

  1. **A genuine, identifying `User-Agent`.** A generic or absent one is grounds for
     being blocked. `@user_agent` carries the project and a contact URL.
  2. **At most ~1 request per second, no heavy bulk use.** This is honoured
     *structurally* rather than by hoping: geocoding happens at **approval time**, which
     is a human clicking a button, so the natural pace is far below the limit. There is
     deliberately **no batch geocoding entry point** — adding one would need a throttle,
     and the absence of the function is a cheaper guarantee than a rate limiter nobody
     tests.

  A self-hosted Nominatim removes both constraints and is a config change
  (`:nominatim_base_url`), not a code change — which is much of the point of choosing it.

  ## Failure behaviour

  Guarded by the shared `:nominatim_fuse`. A `429` is reported as `:rate_limited` rather
  than a generic HTTP error and **melts the fuse**, because continuing to hammer a
  service that has just asked us to stop is how an IP gets blocked — the breaker is the
  thing that makes backing off automatic.
  """

  @behaviour Stacks.Geocoding

  require Logger

  @fuse :nominatim_fuse

  # Policy requirement: identify the application and give an operator a way to reach us.
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
    |> Finch.request(Stacks.Finch, receive_timeout: 10_000)
    |> handle(query)
  end

  @doc false
  # Public so the response handling — which is where all the logic is — can be tested
  # without a network or a stub HTTP server: string-to-float coordinates, an empty list
  # meaning "no match", and a 429 melting the fuse rather than being retried. The request
  # half is a single Finch call with no branching, so mocking it would test Finch.
  def handle({:ok, %Finch.Response{status: 200, body: body}}, query) do
    case Jason.decode(body) do
      # Nominatim returns coordinates as *strings*, and an empty list for no match.
      {:ok, [%{"lat" => lat, "lon" => lon} | _]} ->
        with {latitude, _} <- Float.parse(lat),
             {longitude, _} <- Float.parse(lon) do
          {:ok, %{latitude: latitude, longitude: longitude}}
        else
          # A 200 whose coordinates do not parse is a contract change, not a miss.
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
    # Melt deliberately. Being asked to slow down and not doing so is how the public
    # instance blocks an IP, so the breaker turns "back off" into the default.
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
