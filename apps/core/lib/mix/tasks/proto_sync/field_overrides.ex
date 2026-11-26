defmodule Mix.Tasks.ProtoSync.FieldOverrides do
  @moduledoc """
  The field-classification predicates every generator in this family asks, in
  one place.

  These answer questions about `proto/persisted.exs` — "is this field API-only?",
  "does it reach the warehouse?", "which timestamps does this table carry?" —
  and the answers must be the same for every artefact generated from one
  manifest entry. They were not in one place: `timestamp_field_names/1` existed
  five times byte-identically (the task plus the Ecto, dbt, migration and
  schema.yml generators) and the `api_only` predicate four times, twice as a
  named `defp` and twice inlined into a reject clause alongside `dbt_exclude`.

  ⛔ Duplication is the wrong shape for these specifically, not merely untidy.
  The generators run from a SINGLE manifest entry and must agree about which
  fields exist: an Ecto schema that keeps a column the dbt model drops is drift,
  and drift between generated artefacts is what `mix proto.sync --check` and the
  model-drift gate exist to catch — after the fact, by comparing output. A
  predicate that disagrees with its copy produces artefacts that are each
  internally consistent and wrong together, which is the cheapest way to defeat
  a comparison gate.

  ⚠️ `api_only?/2` and `excluded_from_warehouse?/2` are deliberately separate
  rather than one function with a flag. `api_only: true` means the field has no
  database column at all, so it is absent from the Ecto schema, the migration,
  the dbt model AND schema.yml. `dbt_exclude: true` means the column exists and
  is deliberately withheld from the warehouse — reader free text, a storage key
  — so it must still be declared on the Ecto schema. Collapsing them would make
  a privacy exclusion read as a shape decision.
  """

  @doc """
  True when the field is carried on the API but has no database column.

  Consumed by the task's own filtering and by the Ecto generator. The warehouse
  generators ask `excluded_from_warehouse?/2` instead, which subsumes this.
  """
  @spec api_only?(map(), map()) :: boolean()
  def api_only?(field, overrides) do
    overrides
    |> override_for(field)
    |> Map.get(:api_only, false)
  end

  @doc """
  True when the field must not appear in the dbt model or in `schema.yml`.

  Either it has no column to select (`api_only`), or it has one that is withheld
  from the warehouse on purpose (`dbt_exclude`).
  """
  @spec excluded_from_warehouse?(map(), map()) :: boolean()
  def excluded_from_warehouse?(field, overrides) do
    override = override_for(overrides, field)

    Map.get(override, :api_only, false) or Map.get(override, :dbt_exclude, false)
  end

  @doc """
  The timestamp column names a manifest entry's `timestamps:` setting implies.

  The final clause defaults to both, which matches `timestamps: :standard`: an
  entry that says nothing about timestamps gets them, and only `false` opts out.
  """
  @spec timestamp_field_names(map()) :: [String.t()]
  def timestamp_field_names(%{timestamps: :standard}), do: ~w(created_at updated_at)
  def timestamp_field_names(%{timestamps: {:standard, updated_at: false}}), do: ~w(created_at)
  def timestamp_field_names(%{timestamps: false}), do: []
  def timestamp_field_names(_), do: ~w(created_at updated_at)

  defp override_for(overrides, field) do
    Map.get(overrides, String.to_atom(field.name), %{})
  end
end
