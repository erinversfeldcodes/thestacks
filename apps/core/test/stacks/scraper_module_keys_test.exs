defmodule Stacks.ScraperModuleKeysTest do
  @moduledoc """
  Guards the one hand-maintained coupling between Elixir and the Rust scraper.

  `op.bookstores.scraper_module` must equal the key the Rust `StoreRegistry` derives
  from a TOML's path under `apps/scraper/scrapers/` minus the extension — so
  `"za/exclusive_books"`, not `"exclusive_books"`. Nothing at runtime validates that,
  and the failure is silent in the worst way: the service answers
  `404 store not found` forever, `evaluate_outcome/1` reports the scrape as failed,
  and the store simply never produces a price.

  Measured 2026-07-28 against a live service: **every seeded row was unmatchable**,
  because all of them carried the bare basename. The seed had been that way since it
  was written, and no test noticed.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @scrapers_dir Path.join(@repo_root, "apps/scraper/scrapers")
  @seeds Path.join(@repo_root, "apps/core/priv/repo/seeds.exs")

  # Keys exactly as the Rust registry derives them: the path under scrapers/,
  # extension stripped. See StoreRegistry.load_from_dir.
  defp registry_keys do
    @scrapers_dir
    |> Path.join("**/*.toml")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.relative_to(@scrapers_dir)
      |> String.replace_suffix(".toml", "")
    end)
    |> Enum.sort()
  end

  defp seeded_modules do
    # The seed builds rows from a literal list of
    # {id, name, url, scraper_module, has_physical, unscrapable_reason} tuples, where
    # scraper_module is either a quoted key or `nil`. Only the quoted ones are keys the
    # registry will ever be asked for.
    ~r/\{\d+,\s*"[^"]+",\s*"[^"]+",\s*"([^"]+)",\s*(?:true|false),/
    |> Regex.scan(File.read!(@seeds))
    |> Enum.map(fn [_, module] -> module end)
    |> Enum.sort()
  end

  test "the seed's scraper_module values are real registry keys, not basenames" do
    keys = registry_keys()
    seeded = seeded_modules()

    refute seeded == [], "could not parse any scraper_module out of seeds.exs"
    refute keys == [], "found no scraper TOMLs — has the layout changed?"

    basenames = Map.new(keys, &{Path.basename(&1), &1})

    # The failure mode that actually happened: a value that matches a TOML's
    # basename but not its full key.
    mismatched =
      for m <- seeded,
          m not in keys,
          full = basenames[Path.basename(m)],
          not is_nil(full),
          do: {m, full}

    assert mismatched == [],
           "these scraper_module values name a config that exists under a different key, " <>
             "so the scraper will answer 404 forever: " <>
             Enum.map_join(mismatched, ", ", fn {got, want} -> "#{got} should be #{want}" end)
  end

  test "no seeded store names a config that does not exist" do
    # ⚠️ This case used to be *deliberately allowed*, on the reasoning that a store
    # whose config had not been written yet was "expected and visible". It was neither.
    # Nine of eleven seeded stores named a nonexistent config, and because the key is
    # what the registry looks up, each one was a guaranteed `404 store not found` on
    # every lookup — and the client melts that store's fuse on a non-200. So the
    # "pending" state was indistinguishable from a broken shop, forever.
    #
    # The invariant now: `scraper_module` is non-nil **iff** a TOML exists for it.
    # A store awaiting configuration carries nil, which `Prices.scrapeable_stores/0`
    # excludes structurally, so it is never asked and never melts anything. That turns
    # a silent runtime failure into a pre-merge one.
    keys = registry_keys()
    seeded = seeded_modules()

    phantom = seeded -- keys

    assert phantom == [],
           "these stores name a scraper config that does not exist, so every lookup " <>
             "404s and melts the store's fuse: #{inspect(phantom)}. Either write the " <>
             "TOML or set scraper_module to nil (with an unscrapable_reason if it has " <>
             "been ruled out)."
  end

  test "every scraper TOML is claimed by a seeded store" do
    # The other direction: a config nobody references is dead weight, and worse, it
    # reads as coverage the pipeline does not have.
    keys = registry_keys()
    seeded = seeded_modules()

    unclaimed = keys -- seeded

    assert unclaimed == [],
           "these scraper configs are referenced by no seeded store: #{inspect(unclaimed)}"
  end
end
