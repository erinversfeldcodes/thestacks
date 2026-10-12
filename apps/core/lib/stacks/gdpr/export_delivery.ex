defmodule Stacks.GDPR.ExportDelivery do
  @moduledoc """
      Delivery leg of the GDPR right to portability: takes the map
      `Stacks.GDPR.Export` assembles, serialises it, parks it in object storage
      behind an unguessable key, and mails the user a signed link to it.

      The stored object is a complete second copy of one user's personal data,
      so its lifetime is the control, and the key carries that lifetime itself:

          exports/{user_id}/{unix_deadline}-{token}.json

      - `token` is 32 bytes from `:crypto.strong_rand_bytes/1`. The bucket is
        not publicly listable and every read needs a signature, so the object
        is reachable only by whoever holds the mailed link — no enumeration,
        and no login wall on a link the user asked us to email them.
      - `unix_deadline` lets `sweep_expired/1` find due objects with no
        database row pointing at them. Not writing that row is deliberate: a
        row would be one more copy of the association for erasure to miss, one
        more table for the warehouse to pick up, and it would make the object's
        fate depend on a database that may be a restore behind.
      - The signature expires at the deadline, so an object that outlives the
        sweep by an hour is already unreachable; the sweep closes the retention
        gap, not an access one.
      - `delete_user_exports/1` clears outstanding copies during erasure. When
        storage is down that call cannot succeed, which is the other reason the
        deadline lives in the key: the sweep still collects the object on its
        own schedule even though the user it belonged to is gone.
  """

  require Logger

  alias Stacks.Storage
  alias Stacks.Workers.EmailDeliveryJob

  @prefix "exports"
  @default_ttl_seconds 86_400

  @doc """
      Seconds a mailed export link stays valid — 24 hours by default, and the
      lifetime of the stored object with it. Configurable via
      `config :core, :export_ttl_seconds` so tests can drive expiry without
      waiting a day.
  """
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: Application.get_env(:core, :export_ttl_seconds, @default_ttl_seconds)

  @doc """
      Serialise, store, sign, and enqueue the notification email.

      Every leg can fail and every failure is returned — the caller is an Oban
      job whose retry is the only thing standing between a user and an export
      they were promised.
  """
  @spec deliver(binary(), map()) :: {:ok, map()} | {:error, term()}
  def deliver(user_id, data) do
    ttl = ttl_seconds()
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
    key = key_for(user_id, expires_at)

    with {:ok, json} <- Jason.encode(data),
         {:ok, stored_key} <- Storage.put_export(key, json),
         {:ok, url} <- Storage.signed_download_url(stored_key, ttl),
         {:ok, _job} <- enqueue_email(user_id, url, ttl) do
      {:ok, %{key: stored_key, url: url, expires_at: expires_at, bytes: byte_size(json)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
      Build the storage key for a user's export, deadline first so the sweep
      can read it back without asking anything else.
  """
  @spec key_for(binary(), DateTime.t()) :: String.t()
  def key_for(user_id, %DateTime{} = expires_at) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{@prefix}/#{user_id}/#{DateTime.to_unix(expires_at)}-#{token}.json"
  end

  @doc """
      Read the deadline back out of a storage key. `:error` for a key that does
      not carry one — the sweep will not guess at an object's fate.
  """
  @spec deadline(String.t()) :: {:ok, DateTime.t()} | :error
  def deadline(key) do
    with [unix | _rest] <- key |> Path.basename() |> String.split("-", parts: 2),
         {seconds, ""} <- Integer.parse(unix),
         {:ok, at} <- DateTime.from_unix(seconds) do
      {:ok, at}
    else
      _ -> :error
    end
  end

  @doc """
      Delete every export object whose deadline has passed.

      A delete that fails is the leak this job exists to prevent, so the count
      of survivors is returned as an error and the job retries.
  """
  @spec sweep_expired(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_expired(now \\ DateTime.utc_now()) do
    with {:ok, keys} <- Storage.list_objects(@prefix <> "/") do
      {expired, live} = Enum.split_with(keys, &past_deadline?(&1, now))

      alarm_on_undated(live)

      case delete_all(expired) do
        {count, []} ->
          :telemetry.execute([:stacks, :gdpr, :export, :expired], %{count: count}, %{})
          {:ok, count}

        {_count, failures} ->
          :telemetry.execute(
            [:stacks, :gdpr, :export, :orphan],
            %{count: length(failures)},
            %{}
          )

          {:error, {:export_objects_survived_expiry, length(failures)}}
      end
    end
  end

  @doc """
      Delete every export object belonging to a user. Called during erasure —
      the user's id is the key prefix precisely so this is possible.
  """
  @spec delete_user_exports(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_user_exports(user_id) do
    with {:ok, keys} <- Storage.list_objects("#{@prefix}/#{user_id}/") do
      case delete_all(keys) do
        {count, []} -> {:ok, count}
        {_count, failures} -> {:error, {:export_objects_survived_erasure, length(failures)}}
      end
    end
  end

  defp enqueue_email(user_id, url, ttl) do
    %{
      "template" => "gdpr_export_ready",
      "user_id" => user_id,
      "params" => %{"download_url" => url, "expires_in_seconds" => ttl}
    }
    |> EmailDeliveryJob.new()
    |> Oban.insert()
  end

  defp past_deadline?(key, now) do
    case deadline(key) do
      {:ok, at} -> DateTime.compare(at, now) != :gt
      :error -> false
    end
  end

  defp delete_all(keys) do
    {deleted, failed} =
      Enum.split_with(keys, fn key ->
        case Storage.delete_object(key) do
          :ok ->
            true

          {:error, reason} ->
            Logger.error("ExportDelivery: export object survived deletion: #{inspect(reason)}")
            false
        end
      end)

    {length(deleted), failed}
  end

  defp alarm_on_undated(keys) do
    case Enum.reject(keys, &match?({:ok, _}, deadline(&1))) do
      [] ->
        :ok

      undated ->
        Logger.error(
          "ExportDelivery: ALARM — #{length(undated)} export object(s) carry no deadline and will never be swept"
        )
    end
  end
end
