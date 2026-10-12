defmodule Stacks.IPDigest do
  @moduledoc """
      The one way this system turns a client IP into something storable.

      ## Why this module exists

      Two call sites used to compute `:crypto.hash(:sha256, ip)` independently —
      the audit trail and admin-session pinning. A bare digest of an IP is not
      anonymisation and barely qualifies as pseudonymisation: the IPv4 space is
      2^32, so exhausting it takes about an hour on a single core, and a guessed
      /16 falls in a fraction of a second. Anyone who obtained either column
      obtained recoverable network identifiers.

      Keying fixes that. Without the key an attacker cannot precompute the space,
      so the digest stops being a thin disguise over the address. The property the
      call sites actually need — that the same IP yields the same value, so it can
      be compared — is unchanged.

      ## Where the key comes from

      `secret_key_base`, via a context label, rather than a new secret of its own.
      A dedicated key would be marginally better hygiene; it would also be a new
      required production secret whose absence breaks a deploy, and a rotation
      story nobody asked for. `secret_key_base` already exists in every
      environment and already guards everything else that must not be forgeable.

      ⛔ Rotating `secret_key_base` re-keys every digest. Stored values will stop
      matching newly computed ones. That is survivable exactly because nothing
      here is a long-lived identity: admin sessions expire on their own and a
      failed comparison logs the operator out, which is the safe direction. Do not
      add a call site whose correctness depends on a digest surviving rotation.
  """

  @context "client-ip-digest/v1"

  @doc """
      Keyed digest of a client IP, hex-encoded.

      Deterministic for a given key, so two digests of the same address compare
      equal — and unhelpful to anyone without the key.
  """
  @spec hash(String.t()) :: String.t()
  def hash(raw_ip) when is_binary(raw_ip) do
    :hmac
    |> :crypto.mac(:sha256, key(), raw_ip)
    |> Base.encode16(case: :lower)
  end

  defp key do
    base =
      Application.get_env(:core, CoreWeb.Endpoint, [])
      |> Keyword.get(:secret_key_base) ||
        raise "secret_key_base is not configured; Stacks.IPDigest cannot key a digest without it"

    :crypto.hash(:sha256, @context <> base)
  end
end
