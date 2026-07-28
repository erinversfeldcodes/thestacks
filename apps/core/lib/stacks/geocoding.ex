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

  ⚠️ **Google Geocoding implements this behaviour but is not a config-only swap.** Two
  separate things, previously and wrongly bundled together:

  1. **"It requires Google's own map alongside" is not an obstacle.** Show Google's map —
     that is the normal, supported combination, and it satisfies the requirement. It
     conflicts only with the *decision* recorded in US-3.1.1 §5 (proxied, non-Google
     tiles), and a decision can be revisited. What it actually costs is the reason §5
     went the other way: Google's map JS runs **in the reader's browser**, so every
     reader's IP and viewport goes to Google on every pan and **cannot be proxied**. That
     makes Google a processor to name in the privacy policy and probably a consent
     question, plus it needs `script-src`/`connect-src` in a deliberately strict CSP —
     ⚠️ and whether it needs `unsafe-eval`, which `CLAUDE.md` forbids outright, must be
     checked rather than assumed.

  2. **The caching terms are the constraint that does NOT dissolve.** This design
     *persists* coordinates in `op.third_spaces` and derives `nearest_bookshop_km` from
     them at write time. Google's terms limit retention of returned content, so permanent
     storage plus a derived column is the part that needs a terms reading — and it is
     unaffected by which map is displayed.

  Neither point makes Google wrong; both make it a licensing decision rather than a
  configuration one. ⚠️ **The specifics of Google's current terms are deliberately not
  asserted here** — they change, and the tiles ADR must read them rather than inherit a
  summary written from memory.

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
