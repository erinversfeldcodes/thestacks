defmodule Stacks.EncryptedBinary do
  @moduledoc """
  Cloak-encrypted binary type for Ecto schemas.

  Encrypts binary fields at rest using AES-GCM via `Stacks.Vault`.
  Used for storing sensitive binary data such as TOTP secrets.
  """

  use Cloak.Ecto.Binary, vault: Stacks.Vault
end
