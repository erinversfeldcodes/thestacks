defmodule Stacks.Vault do
  @moduledoc """
    Cloak AES-GCM vault for encrypting sensitive data at rest.

    Used by `Stacks.Audit` to encrypt audit log metadata before storage.
    The encryption key is read from `config:core, Stacks.Vault`.

    In production, set the `CLOAK_KEY` environment variable to a
    base64-encoded 32-byte key. Generate one with:

  :crypto.strong_rand_bytes |> Base.encode64
  """

  use Cloak.Vault, otp_app: :core
end
