defmodule Stacks.EncryptedVector do
  @moduledoc """
      Cloak-encrypted retrieval vector, at rest.

      A writing-assistant embedding is a list of float32s. A PLAINTEXT vector
      column is a near-complete copy of the corpus (vec2text recovers short
      inputs), so the at-rest posture keeps vectors out of the database in the clear:
      the list is packed to a float32 binary and AES-GCM encrypted via
      `Stacks.Vault`, exactly like `Stacks.EncryptedBinary` does for text.

      There is deliberately NO ANN index — an index over the ciphertext buys
      nothing, and an index over plaintext is the leak this type exists to
      prevent. Retrieval decrypts the candidate set and scores it in app memory
      (exact kNN), which the ADR's benchmark showed viable on this corpus.

      float32 (not float64) is the embedding-model-native precision and halves
      the ciphertext; cosine similarity is unaffected.
  """

  use Cloak.Ecto.Type, vault: Stacks.Vault

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_list(value), do: {:ok, value}
  def cast(_), do: :error

  def before_encrypt(value) when is_list(value) do
    for component <- value, into: <<>>, do: <<component::float-32-little>>
  end

  def after_decrypt(value) when is_binary(value) do
    for <<component::float-32-little <- value>>, do: component
  end
end
