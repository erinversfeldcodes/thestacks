defmodule Stacks.DataCorrection.SeedEditionVerificationSourceTest do
  @moduledoc """
  #370's data half: seed-fixture editions the #335 backfill labelled
  `barcode_unverified` are restored to the provenance `seeds.exs` declares —
  and NOTHING else is. The scope cut is the whole correction: a reader-created
  `barcode_unverified` edition is telling the truth and must keep its label.
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Books.BookEdition
  alias Stacks.DataCorrection
  alias Stacks.DataCorrection.SeedEditionVerificationSource

  # A deterministic seed-shaped id no real fixture uses (fixture suffixes are
  # far below 9_990_000). Production writes autogenerate v4 UUIDs, so this
  # prefix is the seed's signature.
  @seed_id "a1b2c3d4-0000-0000-0000-000000999001"

  defp insert_edition(id, verification_source) do
    book = insert(:book)

    Repo.insert!(
      build(:book_edition,
        id: id,
        book: book,
        verification_source: verification_source
      )
    )
  end

  defp source_of(id), do: Repo.get!(BookEdition, id).verification_source

  describe "plan/0 scope" do
    test "claims a seed-shaped edition still carrying the backfill fallback" do
      %{id: id} = insert_edition(@seed_id, "barcode_unverified")

      assert %{from: "barcode_unverified", to: "open_library"} =
               Enum.find(SeedEditionVerificationSource.plan(), &(&1.id == id))
    end

    test "never claims a reader-created barcode_unverified edition — that label is true" do
      # Factory-generated v4 id — the shape every production write path mints.
      %{id: id} =
        Repo.insert!(
          build(:book_edition, book: insert(:book), verification_source: "barcode_unverified")
        )

      refute Enum.any?(SeedEditionVerificationSource.plan(), &(&1.id == id))
    end

    test "never claims a seed-shaped edition already carrying a provider source" do
      %{id: id} = insert_edition("a1b2c3d4-0000-0000-0000-000000999002", "google_books")

      refute Enum.any?(SeedEditionVerificationSource.plan(), &(&1.id == id))
    end
  end

  describe "run/2" do
    test "applies the seed's declared provenance, and a second run is a no-op" do
      %{id: id} = insert_edition(@seed_id, "barcode_unverified")

      assert {:ok, first} =
               DataCorrection.run(SeedEditionVerificationSource,
                 apply: true,
                 invoked_by: "test",
                 reason: "#370 acceptance"
               )

      assert Enum.any?(first.changes, &(&1.id == id))
      assert source_of(id) == "open_library"

      # Idempotence — the DoD's own probe: the second consecutive run plans
      # nothing, because no seed row still holds the fallback.
      assert {:ok, second} =
               DataCorrection.run(SeedEditionVerificationSource,
                 apply: true,
                 invoked_by: "test",
                 reason: "#370 acceptance, second run"
               )

      refute Enum.any?(second.changes, &(&1.id == id))
      assert source_of(id) == "open_library"
    end
  end

  describe "registration" do
    test "the correction is registered, so Stacks.Release.deploy/0 sweeps it" do
      assert SeedEditionVerificationSource in Stacks.DataCorrection.Registry.all()
    end
  end
end
