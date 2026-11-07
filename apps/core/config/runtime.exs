import Config

# ⛔ WHICH OBJECT STORE THIS NODE USES IS DECIDED HERE, BY ASKING, AND A NODE THAT
# CANNOT ANSWER DOES NOT BOOT.
#
# `Stacks.Storage.Selection` was written to make that decision — it is tested, it
# distinguishes "declared local" from "defaulted to local", and it returns an
# error rather than guessing. **It was called by nothing.** `config/config.exs`
# set `:storage` to `Stacks.Storage.Local` at COMPILE time, this file was a single
# `import Config`, and so every environment — including production — ran on the
# compile-time default while a selector sat beside it refusing nothing.
#
# That is why R2 "had never been selected in any deployed environment": not
# because it was configured wrongly, but because nothing selected anything.
# `Stacks.Storage.R2`'s own moduledoc says its config lives "in runtime.exs",
# which until now did not exist.
#
# ⚠️ SKIPPED IN `:test`, deliberately and narrowly. `config/test.exs` sets
# `:storage` to `Stacks.Storage.Mock`, and runtime config is applied AFTER the
# compile-time files — so without this guard every test would run against a real
# backend, and the mock roster would be silently bypassed. The guard is on the
# environment, not on the presence of a declaration, because "no declaration" is
# precisely the case the selector exists to refuse.
if config_env() != :test do
  case Stacks.Storage.Selection.choose(System.get_env(), config_env() == :prod) do
    {:ok, {:local, opts}} ->
      config :core, :storage, Stacks.Storage.Local

      # ⚖️ Only when the selector supplied one. `Stacks.Storage.Local` carries its
      # own default (`priv/static/uploads`), and overwriting it with `nil` here
      # would turn a dev machine's working default into a crash — the selector
      # returns `upload_dir: nil` for a non-deployed build with nothing declared,
      # which is correct for it and wrong to pass straight through.
      if opts[:upload_dir], do: config(:core, :upload_dir, opts[:upload_dir])

    {:ok, {:r2, opts}} ->
      config :core, :storage, Stacks.Storage.R2
      config :core, :r2_bucket, opts[:bucket]

      config :ex_aws, :s3,
        scheme: "https://",
        host: "#{opts[:account_id]}.r2.cloudflarestorage.com",
        region: "auto"

      config :ex_aws,
        access_key_id: opts[:access_key_id],
        secret_access_key: opts[:secret_access_key]

    {:error, message} ->
      # ⛔ RAISE, do not fall back. A fallback here is exactly the defect the
      # selector was written against: uploads landing on a container filesystem
      # that does not survive a restart, while a missing secret looked identical
      # to a working stack. A node that cannot say where bytes go should not take
      # traffic.
      raise message
  end
end
