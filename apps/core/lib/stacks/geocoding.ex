defmodule Stacks.Geocoding do
  @moduledoc """
    Turns a place description into coordinates, behind a provider seam:
    callers depend on this module, `:core,:geocoder` picks the adapter
    (default `Nominatim` — free, no key, and taxonomy is already
    OSM tags). The seam mirrors `:isbn_http_client`/`:scraper_client`.

    ⚠️ Google Geocoding cannot be swapped in for this story (ADR-022):
    Google's ToS forbid storing geocodes beyond a 30-day cache, and the
    stored-coordinates design (write once at approval) is load-bearing for
    the 500m filter. Any replacement must permit indefinite storage.
  """

  @typedoc "A geocoded point, decimal degrees, WGS 84."
  @type point :: %{latitude: float(), longitude: float()}

  @type error :: :not_found | :circuit_open | :rate_limited | {:http, integer()} | term()

  @doc """
    Resolve a free-text place description to a point.

    `{:error,:not_found}` means the provider answered and had no match — a determination,
    not a failure. Anything else is a failure and may be retried.
  """
  @callback geocode(query :: String.t()) :: {:ok, point()} | {:error, error()}

  @doc """
    Geocode via the configured provider.

    The only function callers should use.
  """
  @spec geocode(String.t()) :: {:ok, point()} | {:error, error()}
  def geocode(query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:error, :not_found}
    else
      provider().geocode(query)
    end
  end

  def geocode(_query), do: {:error, :not_found}

  @doc """
    Build a geocoding query from the parts a record actually has.

    Centralised because the assembly is a judgement, not a formatting detail: name plus
    city plus country reads as one place to a geocoder, whereas a bare name matches the
    wrong continent. Nils are dropped rather than rendered, so a space with no city still
    produces a usable query instead of `"Cafe,, ZA"`.
  """
  @spec query_for(%{optional(atom()) => term()}) :: String.t()
  def query_for(attrs) do
    [attrs[:name], attrs[:city], attrs[:country_code]]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(", ")
  end

  defp provider do
    Application.get_env(:core, :geocoder, Stacks.Geocoding.Nominatim)
  end
end
