defmodule Stacks.IPDigestTest do
  use ExUnit.Case, async: true

  alias Stacks.IPDigest

  @ip "197.87.142.19"

  describe "hash/1" do
    test "is deterministic, so a stored digest still compares equal" do
      assert IPDigest.hash(@ip) == IPDigest.hash(@ip)
    end

    test "separates different addresses" do
      refute IPDigest.hash(@ip) == IPDigest.hash("10.0.0.1")
    end

    test "is NOT a bare sha256 of the address — the property the whole module exists for" do
      bare = :crypto.hash(:sha256, @ip) |> Base.encode16(case: :lower)

      refute IPDigest.hash(@ip) == bare,
             "an unkeyed digest is invertible by exhausting the IPv4 space; keying is what stops that"
    end

    test "changing the key changes the digest, so the key is genuinely load-bearing" do
      original = Application.get_env(:core, CoreWeb.Endpoint)
      before = IPDigest.hash(@ip)

      try do
        Application.put_env(
          :core,
          CoreWeb.Endpoint,
          Keyword.put(original, :secret_key_base, String.duplicate("z", 64))
        )

        refute IPDigest.hash(@ip) == before,
               "if the digest survives a key change, the key is not actually mixed in"
      after
        Application.put_env(:core, CoreWeb.Endpoint, original)
      end

      assert IPDigest.hash(@ip) == before, "restoring the key must restore the digest"
    end
  end
end
