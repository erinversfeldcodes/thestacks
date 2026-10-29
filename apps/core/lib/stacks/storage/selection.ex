defmodule Stacks.Storage.Selection do
  @moduledoc """
      Which object-storage backend an environment uses, and whether it said so
      deliberately.

      ⛔ THIS EXISTS BECAUSE THE DECISION USED TO BE A SIDE EFFECT OF A
      CREDENTIAL. `config/runtime.exs` selected R2 whenever `R2_ACCOUNT_ID`
      happened to be set, which is not the same question as "which backend
      should this environment use", and the difference was measured rather than
      imagined:

        - a developer machine with credentials in `.env` silently read, wrote
          and deleted objects in the shared bucket — of 25 keys sampled from it,
          13 had rows in the production database;
        - a deployed stack without those secrets silently fell back to
          `Stacks.Storage.Local`, writing reader photos to a container
          filesystem with no volume behind it, on a machine that stops when
          idle. Nothing reported it and every gate stayed green.

      ⚖️ `Local` IS A LEGITIMATE PRODUCTION CHOICE and stays allowed. The Stacks
      is self-hosted; an operator on one machine with a real disk needs no
      object storage. What is refused is choosing it by accident — so a
      deployed build must name both the backend and, for `Local`, the durable
      location.

      ⚠️ The logic lives here rather than inline in `runtime.exs` so that every
      branch — including the two that refuse to boot — has a test. A config file
      is the one place where "it looked right" is the only check available, and
      this one had been wrong in production for seven months.
  """

  @typedoc "The chosen backend and the settings that follow from it."
  @type choice :: {:r2, keyword()} | {:local, keyword()}

  @doc """
      Decide from an environment map and whether this is a deployed build.

      `env` is `System.get_env()`. `deployed?` is `config_env() == :prod`.
      Returns `{:ok, choice}` or `{:error, message}` — the caller raises, so
      that this function stays testable.
  """
  @spec choose(map(), boolean()) :: {:ok, choice()} | {:error, String.t()}
  def choose(env, deployed?) when is_map(env) and is_boolean(deployed?) do
    case declared(env, "STORAGE_BACKEND") do
      nil -> default_for(env, deployed?)
      "r2" -> r2(env)
      "local" -> local(env, deployed?)
      other -> {:error, ~s(STORAGE_BACKEND must be "r2" or "local", got: #{inspect(other)})}
    end
  end

  defp default_for(env, false), do: local(env, false)

  defp default_for(env, true) do
    # A deployed build with no declaration defaults to R2 — and its absence is
    # an error, never a downgrade to a disk nobody promised to keep.
    if declared(env, "R2_ACCOUNT_ID") do
      r2(env)
    else
      {:error,
       """
       No object storage is configured for a deployed build.

       This used to fall back to Stacks.Storage.Local, which writes to the
       container filesystem — so uploads were lost on the next deploy and a
       missing secret looked exactly like a working stack.

       Set R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and
       R2_BUCKET_NAME, or choose local storage deliberately with
       STORAGE_BACKEND=local plus UPLOAD_DIR=/path/on/a/durable/volume.
       """}
    end
  end

  defp r2(env) do
    required = ~w(R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_NAME)

    case Enum.reject(required, &declared(env, &1)) do
      [] ->
        {:ok,
         {:r2,
          account_id: declared(env, "R2_ACCOUNT_ID"),
          access_key_id: declared(env, "R2_ACCESS_KEY_ID"),
          secret_access_key: declared(env, "R2_SECRET_ACCESS_KEY"),
          bucket: declared(env, "R2_BUCKET_NAME")}}

      missing ->
        # ⚠️ NAMED, not counted. A deploy that lost one secret should not have
        # to bisect four.
        {:error,
         "R2 storage is selected but these are missing or blank: #{Enum.join(missing, ", ")}"}
    end
  end

  defp local(env, true) do
    case declared(env, "UPLOAD_DIR") do
      nil ->
        {:error,
         """
         STORAGE_BACKEND=local in a deployed build requires UPLOAD_DIR.

         Point it at a path on a durable volume. Without one, uploads live on
         the container filesystem and are lost on redeploy — the silent data
         loss this setting exists to make impossible to choose by accident.
         """}

      dir ->
        {:ok, {:local, upload_dir: dir}}
    end
  end

  defp local(env, false), do: {:ok, {:local, upload_dir: declared(env, "UPLOAD_DIR")}}

  # ⛔ BLANK IS ABSENT. `System.get_env/1` answers `""` for a variable that is
  # set to nothing, and `""` is truthy in Elixir — so the original
  # `if System.get_env("R2_ACCOUNT_ID")` would have selected R2 on an empty
  # secret and built the host `".r2.cloudflarestorage.com"`. A secret store that
  # can hold an empty string makes this a real input, not a pedantic one.
  defp declared(env, key) do
    case env |> Map.get(key, "") |> String.trim() do
      "" -> nil
      value -> value
    end
  end
end
