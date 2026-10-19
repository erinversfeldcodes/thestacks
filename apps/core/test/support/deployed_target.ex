defmodule Core.DeployedTarget do
  @moduledoc """
      The shared guard for `:deployed_only` test modules: refuses a LOCAL target
      instead of quietly measuring one.

      ## The hole this closes

      Each of these modules skips when its variable is UNSET. None of them
      checked whether the value is local — and this repository's own `.env` sets
      `DATABASE_URL` to `postgres://…@localhost:5432/stacks_dev`.

      ⚠️ **What that actually produced, measured rather than assumed.** All three
      modules connect with `ssl: [verify: :verify_none]`, and a default local
      Postgres has `ssl = off` and rejects the handshake outright
      (`server does not support SSL, but SSL was required`). So pointing them at
      localhost did NOT yield a false pass — it yielded a connection error. The
      behaviour was fail-closed, and an earlier draft of this note claiming
      otherwise was wrong.

      What was actually wrong is worth fixing anyway, for two reasons:

        * the failure was a Postgrex SSL error several frames down, which tells a
          reader nothing about the real mistake — that they asked for deployed
          tests and supplied a sandbox;
        * fail-closed here is an ACCIDENT of local SSL being off. On a machine
          whose local Postgres has SSL enabled, the connection succeeds, the
          roles and grants are all present locally, and the suite passes having
          proven nothing. Production holds all three least-privilege roles;
          staging holds none. A green from a sandbox distinguishes neither.

      `scripts/dbt-deployed.sh` already refuses a local host rather than relying
      on a downstream error, with the same reasoning written above its guard.
      This is that guard for the ExUnit half.

      ## Why a failure and not a skip

      These modules are excluded by default, so they run only when somebody asks
      for them by tag. Asking for deployed tests and supplying a local target is
      a misconfiguration of a deliberate request, and `scripts/test-deployed.sh`
      is built on the same principle — it requires both variables up front
      because, in its words, that is what stops a vacuous green. A skip here
      would be a third way to get one.
  """

  @local_hosts ~w(localhost 127.0.0.1 ::1 0.0.0.0)

  @doc """
      Raises unless `var` names a non-local target.

      Call from `setup`. Returns `:ok` so it composes in a setup block.
  """
  @spec require_deployed!(String.t()) :: :ok
  def require_deployed!(var) do
    value = System.get_env(var)

    cond do
      value in [nil, ""] ->
        raise """
        #{var} is not set.

        This module is tagged `:deployed_only` and was asked for explicitly, so
        there is a target expected and none was given. Nothing was measured.
        """

      local?(value) ->
        raise """
        #{var} points at a LOCAL target: #{redact(value)}

        This module only means something against a deployed stack. A local
        sandbox has the roles, the grants and the schema a deployed database may
        well be missing — measured on 2026-10-19, production held all three
        least-privilege roles and staging held none, while a local database held
        all three. A pass here would prove nothing about either.

        Point #{var} at a preview or production target, or do not ask for the
        `deployed_only` tag.
        """

      true ->
        :ok
    end
  end

  @doc "Whether `value` (a URL or bare host) names a local host."
  @spec local?(String.t()) :: boolean()
  def local?(value) when is_binary(value) do
    host = host_of(value)

    host in @local_hosts or
      String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".test")
  end

  defp host_of(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      # A bare host, or a scheme URI parses badly — fall back to the string so a
      # value like "localhost" is still caught rather than treated as remote.
      _ -> value |> String.split("/") |> List.last() |> String.split(":") |> List.first()
    end
  end

  # ⚠️ Never echo the value verbatim: a DATABASE_URL carries a password, and this
  # message lands in test output and CI logs. The host is the whole point of the
  # message and the only part that is safe to show.
  defp redact(value) do
    host = host_of(value)
    "host=#{host}"
  end
end
