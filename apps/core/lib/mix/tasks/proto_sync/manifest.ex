defmodule Mix.Tasks.ProtoSync.Manifest do
  @moduledoc "Loads and validates the proto persistence manifest (persisted.exs)."

  @doc """
    Loads and validates the proto sync manifest from `proto/persisted.exs`.

    Returns a map with `:version` and `:tables` keys. Each table entry contains
    the proto-to-schema mapping configuration.
  """
  def load!(path) do
    unless File.exists?(path) do
      raise("Manifest not found at #{path}. Create proto/persisted.exs first.")
    end

    {manifest, _bindings} = Code.eval_file(path)
    validate!(manifest, path)
    manifest
  end

  defp validate!(manifest, path) do
    unless is_map(manifest) and is_integer(manifest[:version]) and is_list(manifest[:tables]) do
      raise("Invalid manifest structure in #{path}. Expected %{version: integer, tables: list}.")
    end

    Enum.each(manifest.tables, &validate_table!(&1, path))
  end

  @required_table_keys [
    :proto_file,
    :proto_message,
    :table_name,
    :schema_prefix,
    :ecto_module,
    :ecto_path,
    :dbt_path
  ]

  defp validate_table!(table, path) do
    Enum.each(@required_table_keys, fn key ->
      unless Map.has_key?(table, key) do
        raise("Table entry missing required key :#{key} in #{path}.")
      end
    end)
  end
end
