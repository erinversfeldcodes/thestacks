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
    keys = registry_keys()
    seeded = seeded_modules()

    unclaimed = keys -- seeded

    assert unclaimed == [],
           "these scraper configs are referenced by no seeded store: #{inspect(unclaimed)}"
  end
end
