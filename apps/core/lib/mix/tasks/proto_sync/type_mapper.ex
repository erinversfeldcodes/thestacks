defmodule Mix.Tasks.ProtoSync.TypeMapper do
  @moduledoc "Maps proto descriptor types to Ecto schema types and migration types."

  @doc """
  Maps a proto descriptor field type to an Ecto schema type.

  Handles scalar types, well-known types (Timestamp, Struct), and enums.
  Field overrides from the manifest take precedence.
  """
  def ecto_type(field, overrides \\ %{}) do
    field_name = String.to_atom(field.name)
    override = Map.get(overrides, field_name, %{})

    base_type =
      if Map.has_key?(override, :ecto_type) do
        override.ecto_type
      else
        map_proto_type(field.type, field.type_name)
      end

    if field.label == "LABEL_REPEATED" and not match?({:array, _}, base_type) do
      {:array, base_type}
    else
      base_type
    end
  end

  @doc """
  Maps a proto descriptor field type to an Ecto migration type.

  Migration types differ from schema types in a few cases:
  - `TYPE_STRING` → `:text` (not `:string`) — unbounded text in Postgres
  - `TYPE_INT64` → `:bigint` (not `:integer`)
  - `TYPE_ENUM` → `:text` (not `:string`)

  Field overrides with `:migration_type` take highest precedence,
  then `:ecto_type` overrides, then the default mapping.
  """
  def migration_type(field, overrides \\ %{}) do
    field_name = String.to_atom(field.name)
    override = Map.get(overrides, field_name, %{})

    base_type =
      cond do
        Map.has_key?(override, :migration_type) -> override.migration_type
        Map.has_key?(override, :ecto_type) -> override.ecto_type
        Map.has_key?(override, :belongs_to) -> :binary_id
        true -> map_migration_type(field.type, field.type_name)
      end

    if field.label == "LABEL_REPEATED" and not match?({:array, _}, base_type) do
      {:array, base_type}
    else
      base_type
    end
  end

  @doc """
  Returns the default value for a field, if specified in overrides.

  Fragment defaults (`{:fragment, sql}`) are migration-only and excluded here.
  Use `migration_default/2` for migration generation.
  """
  def default(field, overrides \\ %{}) do
    field_name = String.to_atom(field.name)

    case Map.get(overrides, field_name, %{}) do
      %{default: {:fragment, _}} -> :none
      %{default: default} -> {:ok, default}
      _ -> :none
    end
  end

  @doc """
  Returns the default value for a field for use in migrations.

  Includes fragment defaults (`{:fragment, sql}`) that are not valid in schemas.
  """
  def migration_default(field, overrides \\ %{}) do
    field_name = String.to_atom(field.name)

    case Map.get(overrides, field_name, %{}) do
      %{default: default} -> {:ok, default}
      _ -> :none
    end
  end

  defp map_proto_type("TYPE_STRING", _), do: :string
  defp map_proto_type("TYPE_INT32", _), do: :integer
  defp map_proto_type("TYPE_UINT32", _), do: :integer
  defp map_proto_type("TYPE_SINT32", _), do: :integer
  defp map_proto_type("TYPE_FIXED32", _), do: :integer
  defp map_proto_type("TYPE_SFIXED32", _), do: :integer
  defp map_proto_type("TYPE_INT64", _), do: :integer
  defp map_proto_type("TYPE_UINT64", _), do: :integer
  defp map_proto_type("TYPE_SINT64", _), do: :integer
  defp map_proto_type("TYPE_FIXED64", _), do: :integer
  defp map_proto_type("TYPE_SFIXED64", _), do: :integer
  defp map_proto_type("TYPE_FLOAT", _), do: :float
  defp map_proto_type("TYPE_DOUBLE", _), do: :float
  defp map_proto_type("TYPE_BOOL", _), do: :boolean
  defp map_proto_type("TYPE_BYTES", _), do: :binary

  defp map_proto_type("TYPE_MESSAGE", "." <> type_name) do
    case type_name do
      "google.protobuf.Timestamp" ->
        :utc_datetime_usec

      "google.protobuf.Struct" ->
        :map

      _other ->
        :map
    end
  end

  defp map_proto_type("TYPE_ENUM", _), do: :string

  defp map_proto_type(type, type_name) do
    raise(
      "Unmapped proto type: #{type} (typeName: #{inspect(type_name)}). Add a field_override or update the type mapper."
    )
  end

  defp map_migration_type("TYPE_STRING", _), do: :text
  defp map_migration_type("TYPE_INT32", _), do: :integer
  defp map_migration_type("TYPE_UINT32", _), do: :integer
  defp map_migration_type("TYPE_SINT32", _), do: :integer
  defp map_migration_type("TYPE_FIXED32", _), do: :integer
  defp map_migration_type("TYPE_SFIXED32", _), do: :integer
  defp map_migration_type("TYPE_INT64", _), do: :bigint
  defp map_migration_type("TYPE_UINT64", _), do: :bigint
  defp map_migration_type("TYPE_SINT64", _), do: :bigint
  defp map_migration_type("TYPE_FIXED64", _), do: :bigint
  defp map_migration_type("TYPE_SFIXED64", _), do: :bigint
  defp map_migration_type("TYPE_FLOAT", _), do: :float
  defp map_migration_type("TYPE_DOUBLE", _), do: :float
  defp map_migration_type("TYPE_BOOL", _), do: :boolean
  defp map_migration_type("TYPE_BYTES", _), do: :binary
  defp map_migration_type("TYPE_ENUM", _), do: :text

  defp map_migration_type("TYPE_MESSAGE", "." <> type_name) do
    case type_name do
      "google.protobuf.Timestamp" ->
        :utc_datetime_usec

      "google.protobuf.Struct" ->
        :map

      _other ->
        :map
    end
  end

  defp map_migration_type(type, type_name) do
    raise(
      "Unmapped proto type: #{type} (typeName: #{inspect(type_name)}). Add a field_override or update the type mapper."
    )
  end
end
