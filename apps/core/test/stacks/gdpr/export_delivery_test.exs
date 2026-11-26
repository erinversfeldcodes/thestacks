defmodule Stacks.GDPR.ExportDeliveryTest do
  @moduledoc """
      Tests for Stacks.GDPR.ExportDelivery — the leg that turns an export map
      into an object a user can actually download, and takes it away again.

      The guarantees under test are the ones a user is relying on: the export
      reaches them, nobody else can reach it, and the copy does not outlive the
      link they were sent.
  """

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Stacks.Factory

  alias Stacks.GDPR.ExportDelivery
  alias Stacks.Storage
  alias Stacks.Workers.EmailDeliveryJob

  setup do
    Storage.Mock.clear()
    on_exit(&Storage.Mock.clear/0)
    :ok
  end

  defp stored_keys(prefix \\ "exports/") do
    {:ok, keys} = Storage.list_objects(prefix)
    keys
  end

  describe "deliver/2" do
    test "stores the export as JSON under the user's export prefix" do
      user = insert(:user)

      assert {:ok, %{key: key}} = ExportDelivery.deliver(user.id, %{user: %{id: user.id}})

      assert String.starts_with?(key, "exports/#{user.id}/")
      assert String.ends_with?(key, ".json")
      assert {:ok, %{"user" => %{"id" => id}}} = Jason.decode(Storage.Mock.get(key))
      assert id == user.id
    end

    test "signs the download URL for exactly the export TTL" do
      user = insert(:user)

      assert {:ok, %{key: key, url: url}} = ExportDelivery.deliver(user.id, %{ok: true})

      assert url =~ key
      assert url =~ "expires_in=#{ExportDelivery.ttl_seconds()}"
    end

    test "enqueues the export-ready email carrying the download URL" do
      user = insert(:user)

      assert {:ok, %{url: url}} = ExportDelivery.deliver(user.id, %{ok: true})

      assert_enqueued(
        worker: EmailDeliveryJob,
        args: %{
          "template" => "gdpr_export_ready",
          "user_id" => user.id,
          "params" => %{"download_url" => url, "expires_in_seconds" => 86_400}
        }
      )
    end

    test "the stored object's deadline matches the link's" do
      user = insert(:user)

      assert {:ok, %{key: key, expires_at: expires_at}} =
               ExportDelivery.deliver(user.id, %{ok: true})

      assert {:ok, deadline} = ExportDelivery.deadline(key)
      assert DateTime.diff(deadline, expires_at) == 0
    end

    test "two exports for the same user never share a key" do
      user = insert(:user)

      assert {:ok, %{key: first}} = ExportDelivery.deliver(user.id, %{ok: true})
      assert {:ok, %{key: second}} = ExportDelivery.deliver(user.id, %{ok: true})

      refute first == second
      assert length(stored_keys()) == 2
    end

    test "the key's token is 32 bytes of entropy, not a guessable id" do
      user = insert(:user)
      deadline = DateTime.add(DateTime.utc_now(), 3600, :second)

      token =
        user.id
        |> ExportDelivery.key_for(deadline)
        |> Path.basename(".json")
        |> String.split("-", parts: 2)
        |> List.last()

      assert String.length(token) == 64
      assert {:ok, raw} = Base.decode16(token, case: :lower)
      assert byte_size(raw) == 32
    end

    test "a storage failure fails the delivery instead of reporting success" do
      user = insert(:user)
      Storage.Mock.steer_error(:put, :circuit_open)

      assert {:error, :circuit_open} = ExportDelivery.deliver(user.id, %{ok: true})
      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "a signing failure fails the delivery and mails nobody a dead link" do
      user = insert(:user)
      Storage.Mock.steer_error(:presign, :signing_unavailable)

      assert {:error, :signing_unavailable} = ExportDelivery.deliver(user.id, %{ok: true})
      refute_enqueued(worker: EmailDeliveryJob)
    end

    test "data that cannot be serialised fails the delivery" do
      user = insert(:user)

      assert {:error, %Protocol.UndefinedError{protocol: Jason.Encoder}} =
               ExportDelivery.deliver(user.id, %{pid: self()})

      assert stored_keys() == []
    end
  end

  describe "deadline/1" do
    test "reads the deadline back out of a key" do
      at = DateTime.add(DateTime.utc_now(), 600, :second)
      key = ExportDelivery.key_for(Ecto.UUID.generate(), at)

      assert {:ok, read_back} = ExportDelivery.deadline(key)
      assert DateTime.to_unix(read_back) == DateTime.to_unix(at)
    end

    test "refuses to guess at a key that carries no deadline" do
      assert :error = ExportDelivery.deadline("exports/#{Ecto.UUID.generate()}/loose-file.json")
    end
  end

  describe "sweep_expired/1" do
    test "deletes objects whose deadline has passed" do
      key = expired_object(Ecto.UUID.generate())

      assert {:ok, 1} = ExportDelivery.sweep_expired()
      assert Storage.Mock.get(key) == nil
    end

    test "leaves objects whose link is still live" do
      user_id = Ecto.UUID.generate()
      key = ExportDelivery.key_for(user_id, DateTime.add(DateTime.utc_now(), 3600, :second))
      Storage.Mock.seed(key, "{}")

      assert {:ok, 0} = ExportDelivery.sweep_expired()
      assert Storage.Mock.get(key) == "{}"
    end

    test "sweeps every user's expired objects, not just one" do
      expired_object(Ecto.UUID.generate())
      expired_object(Ecto.UUID.generate())

      assert {:ok, 2} = ExportDelivery.sweep_expired()
      assert stored_keys() == []
    end

    test "a delete that fails is reported, not counted as swept" do
      expired_object(Ecto.UUID.generate())
      Storage.Mock.steer_error(:delete, :circuit_open)

      assert {:error, {:export_objects_survived_expiry, 1}} = ExportDelivery.sweep_expired()
    end

    test "a listing failure fails the sweep" do
      Storage.Mock.steer_error(:list, :circuit_open)

      assert {:error, :circuit_open} = ExportDelivery.sweep_expired()
    end

    test "emits expiry telemetry so a silent sweep is visible" do
      expired_object(Ecto.UUID.generate())

      :telemetry.attach(
        "export-sweep-test",
        [:stacks, :gdpr, :export, :expired],
        fn _event, measurements, _meta, pid -> send(pid, {:swept, measurements}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("export-sweep-test") end)

      assert {:ok, 1} = ExportDelivery.sweep_expired()
      assert_received {:swept, %{count: 1}}
    end

    test "an object carrying no deadline raises an observable alarm, not just a log line" do
      # ⛔ An export key with no parseable deadline is not merely late: the sweep
      # selects by deadline, so it can NEVER select this object. It is a copy of
      # a reader's personal data that stays in the bucket permanently.
      #
      # ⚠️ This alarm was log-only while its two siblings (`:expired` and
      # `:orphan`) had been given metrics in an earlier pass that recorded, in a
      # comment, that they were "emitted into nothing". This one was beside them
      # and missed — the same fix-where-found shape — and it is the one of the
      # three whose failure is permanent rather than delayed.
      #
      # A log line is read when somebody is already suspicious. Nothing about
      # this condition would ever make them suspicious, which is exactly why it
      # needs a number.
      Storage.Mock.seed("exports/no-deadline-here.json", "{}")

      :telemetry.attach(
        "export-undated-test",
        [:stacks, :gdpr, :export, :undated],
        fn _event, measurements, _meta, pid -> send(pid, {:undated, measurements}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("export-undated-test") end)

      ExportDelivery.sweep_expired()

      assert_received {:undated, %{count: count}}

      assert count >= 1,
             "the undated object raised no telemetry, so an export that can never be swept is " <>
               "invisible outside a log line nobody reads"
    end
  end

  describe "delete_user_exports/1" do
    test "erases every outstanding export belonging to the user" do
      user_id = Ecto.UUID.generate()
      live = ExportDelivery.key_for(user_id, DateTime.add(DateTime.utc_now(), 3600, :second))
      Storage.Mock.seed(live, "{}")
      expired = expired_object(user_id)

      assert {:ok, 2} = ExportDelivery.delete_user_exports(user_id)
      assert Storage.Mock.get(live) == nil
      assert Storage.Mock.get(expired) == nil
    end

    test "leaves other users' exports alone" do
      mine = Ecto.UUID.generate()
      theirs = ExportDelivery.key_for(Ecto.UUID.generate(), DateTime.utc_now())
      Storage.Mock.seed(theirs, "{}")
      Storage.Mock.seed(ExportDelivery.key_for(mine, DateTime.utc_now()), "{}")

      assert {:ok, 1} = ExportDelivery.delete_user_exports(mine)
      assert Storage.Mock.get(theirs) == "{}"
    end

    test "reports a copy that survived erasure" do
      user_id = Ecto.UUID.generate()
      expired_object(user_id)
      Storage.Mock.steer_error(:delete, :circuit_open)

      assert {:error, {:export_objects_survived_erasure, 1}} =
               ExportDelivery.delete_user_exports(user_id)
    end
  end

  defp expired_object(user_id) do
    key = ExportDelivery.key_for(user_id, DateTime.add(DateTime.utc_now(), -60, :second))
    Storage.Mock.seed(key, "{}")
    key
  end
end
