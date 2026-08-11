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

  ⚠️ **Google Geocoding cannot be swapped in for this story — see ADR 022.** Not for the
  reason an earlier version of this comment gave (which was circular), and not because of
  the caching terms (which permit indefinite lat/lng storage for end-user-facing features
  like ours). The actual chain, each link verified 2026-07-28:

      Google Geocoding → its policy requires results *displayed on a map* to be shown on a
      **Google map** → Google Maps JS requires **`'unsafe-eval'`** in `script-src`, even in
      Google's own recommended strict CSP → `unsafe-eval` is forbidden outright
      (`CLAUDE.md:144`, `security.md:139`); the live policy is `script-src 'self'`.

  Google Geocoding *is* usable where results are **not displayed on a map** — attribution
  suffices there. So this seam is genuinely provider-agnostic for a list or an admin queue;
  it is the map that forecloses Google, not the geocoding.

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
