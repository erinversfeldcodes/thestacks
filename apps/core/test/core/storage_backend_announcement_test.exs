defmodule Core.StorageBackendAnnouncementTest do
  @moduledoc """
      The boot line exists because a correct SILENT choice is still silent, and
      silence is what let every environment run `Local` — uploads on a container
      filesystem — for seven months with nothing saying so.

      ⛔ These cases assert the line is EMITTED and NAMES the thing an operator
      needs, which is the backend plus which bucket or directory. "R2" alone does
      not distinguish production's bucket from a preview's, and that ambiguity is
      what made a preview deploy able to write into production's bucket.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  setup do
    original = Application.get_env(:core, :storage)
    bucket = Application.get_env(:core, :r2_bucket)
    dir = Application.get_env(:core, :upload_dir)

    # ⛔ `apps/core/config/test.exs` sets `config :logger, level: :warning`, so the
    # R2 branch — an `:info` line — is FILTERED and `capture_log` returns "". Both
    # :info cases failed on an empty capture before this, which looked like the
    # announcement not firing and was the test being deaf to it.
    #
    # ⚖️ The levels are NOT a defect and were left alone: `prod.exs` runs
    # `level: :info`, so the R2 line is visible where it matters, and the
    # asymmetry is deliberate — R2 is the intended state and announces itself at
    # :info, while `Local` on a deployed stack is nearly always a mistake and is
    # the one an operator scanning for problems must not miss.
    previous_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: previous_level)
      put_or_delete(:storage, original)
      put_or_delete(:r2_bucket, bucket)
      put_or_delete(:upload_dir, dir)
    end)

    :ok
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:core, key)
  defp put_or_delete(key, value), do: Application.put_env(:core, key, value)

  test "R2 is announced with its bucket, so one R2 stack is distinguishable from another" do
    Application.put_env(:core, :storage, Stacks.Storage.R2)
    Application.put_env(:core, :r2_bucket, "a-named-bucket")

    log = capture_log(fn -> Core.Application.announce_storage_backend() end)

    assert log =~ "storage backend: R2"
    assert log =~ "a-named-bucket"
  end

  test "Local is announced as a WARNING that says the bytes do not survive the node" do
    Application.put_env(:core, :storage, Stacks.Storage.Local)
    Application.put_env(:core, :upload_dir, "/somewhere/transient")

    log = capture_log(fn -> Core.Application.announce_storage_backend() end)

    assert log =~ "storage backend: Local"
    assert log =~ "/somewhere/transient"

    # ⛔ The severity is the message. An operator scanning for problems must see
    # this one, because on a deployed stack it is nearly always a mistake — and
    # when it is deliberate, it is still the fact most worth knowing about that
    # node. At :info it reads as routine.
    assert log =~ "[warning]"
    assert log =~ "do not survive"
  end

  test "an unset bucket is reported as UNSET rather than as an empty name" do
    Application.put_env(:core, :storage, Stacks.Storage.R2)
    Application.delete_env(:core, :r2_bucket)

    log = capture_log(fn -> Core.Application.announce_storage_backend() end)

    # A blank where the bucket should be reads as "no bucket configured" only if
    # you already suspect it. Saying UNSET costs nothing and removes the guess —
    # the same reasoning that made a blank secret counting as "present" a defect.
    assert log =~ "UNSET"
  end
end
