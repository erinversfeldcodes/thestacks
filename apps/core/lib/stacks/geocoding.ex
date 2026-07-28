defmodule Stacks.Geocoding do
  @moduledoc """
  Turns a place description into coordinates.

  ## Why a behaviour rather than one module

  The provider is expected to change. Nominatim (OpenStreetMap) is the right choice
  *now* — free, no key, and US-3.1.1's category taxonomy is already OSM tags, so the
  vocabularies match — but its accuracy on business names is weaker than Google's, and
  the day that matters the swap should be a config line, not a refactor.

  So callers depend on this module, never on a provider. `Stacks.Geocoding.Nominatim` is
  the default; point `:core, :geocoder` at another adapter to switch. The seam mirrors
  `:isbn_http_client` and `:scraper_client`, which is the project's existing idiom for
  exactly this.

  ⚠️ **Google Geocoding is not a drop-in despite implementing this behaviour.** Its
  terms restrict caching coordinates and generally require Google's own map to be shown
  alongside — which contradicts the tile ruling in US-3.1.1 §5 (proxied, non-Google
  tiles). Adopting it is a licensing decision, not a configuration one, and belongs in
  the tiles ADR rather than here.

  ## The contract

  `geocode/1` takes a free-text description ("The Book Lounge, Cape Town") and returns a
  point or an error. It deliberately does **not** take a struct: geocoding a bookshop and
  geocoding a third space are the same operation, and a shared interface keeps one
  provider integration instead of two.

  Returning `{:error, :not_found}` for "no match" separately from a transport failure
  matters to callers: a space that cannot be geocoded is a real, visible state the owner
  must be able to see, whereas a transport failure should be retried.
  """

  @typedoc "A geocoded point, decimal degrees, WGS 84."
  @type point :: %{latitude: float(), longitude: float()}

  @type error :: :not_found | :circuit_open | :rate_limited | {:http, integer()} | term()

  @doc """
  Resolve a free-text place description to a point.

  `{:error, :not_found}` means the provider answered and had no match — a determination,
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
      # Guarded here rather than in each adapter: an empty query is a caller bug, and
      # every provider would answer it with an unhelpful match or a wasted request.
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
  produces a usable query instead of `"Cafe, , ZA"`.
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
