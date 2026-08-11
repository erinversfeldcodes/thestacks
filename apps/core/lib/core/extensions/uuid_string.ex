defmodule Core.Extensions.UUIDString do
  @moduledoc """
    Custom Postgrex extension that accepts both 16-byte binary UUIDs and
    36-character string UUIDs. This allows raw table queries (e.g.
    `from(t in "table_name", where: t.uuid_col == ^string_uuid)`) to work
    without requiring callers to call `Ecto.UUID.dump!/1` manually.
  """

  import Postgrex.BinaryUtils, warn: false
  use Postgrex.BinaryExtension, send: "uuid_send"

  def init(opts), do: Keyword.get(opts, :decode_binary, :reference)

  def encode(_) do
    quote location: :keep, generated: true do
      uuid when is_binary(uuid) and byte_size(uuid) == 16 ->
        [<<16::signed-32>> | uuid]

      uuid when is_binary(uuid) and byte_size(uuid) == 36 ->
        case Ecto.UUID.dump(uuid) do
          {:ok, bin} -> [<<16::signed-32>> | bin]
          :error -> raise DBConnection.EncodeError, "invalid UUID string: #{inspect(uuid)}"
        end

      other ->
        raise DBConnection.EncodeError,
              Postgrex.Utils.encode_msg(other, "a 16-byte binary or 36-char UUID string")
    end
  end

  def decode(:copy) do
    quote location: :keep do
      <<16::signed-32, uuid::binary-16>> -> :binary.copy(uuid)
    end
  end

  def decode(:reference) do
    quote location: :keep do
      <<16::signed-32, uuid::binary-16>> -> uuid
    end
  end
end
