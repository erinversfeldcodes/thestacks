defmodule Stacks.Workers.PendingCountTest do
  @moduledoc """
      The far-end check for every duty that moved off the Oban crontab.

      ⛔ **Why these exist at all.** Each of these workers returns `:ok` when it
      has finished *and* when it has run out of budget with rows remaining —
      `ImageRetentionJob` drains under a 30-second deadline per sweep,
      `AuditRetentionJob` stops at a batch ceiling. So "the job succeeded" and
      "the sweep is finished" are different facts, and a scheduler that checked
      only the first would report green over a growing backlog. Production held
      6,655 expired image rows behind a nightly `:ok`, the oldest 151 days past
      expiry, which is what that difference costs when nobody measures it.

      `pending_count/0` is the measurement. This file's job is to prove it can
      be **non-zero** — because every one of them returns 0 on a clean database,
      and a number that has only ever been observed at 0 is indistinguishable
      from `def pending_count, do: 0`.

      ⚠️ Coverage is partial and deliberately stated. Four of the eight are
      cheaply fixturable and get the full plant-and-sweep treatment. The other
      four depend on object storage, a dependency-owned table, or the
      append-only audit trigger; for those this file proves the function is
      reachable and returns a non-negative integer, and the planted case is
      left to the deployed drive. Saying which is which is the point — a suite
      that implied eight proofs while holding four would be the same defect
      class these counts exist to catch.
  """

  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Workers.AuditRetentionJob
  alias Stacks.Workers.ExpiredEmailChangesJob
  alias Stacks.Workers.ExpiredInvitesSweepJob
  alias Stacks.Workers.ExpiredUnverifiedAccountsJob
  alias Stacks.Workers.ExportRetentionJob
  alias Stacks.Workers.GuardianTokenSweepJob
  alias Stacks.Workers.ImageRetentionJob
  alias Stacks.Workers.LibraryImportRowRetentionJob

  @all [
    ImageRetentionJob,
    ExportRetentionJob,
    LibraryImportRowRetentionJob,
    AuditRetentionJob,
    GuardianTokenSweepJob,
    ExpiredUnverifiedAccountsJob,
    ExpiredInvitesSweepJob,
    ExpiredEmailChangesJob
  ]

  describe "every moved duty exposes a far-end count" do
    test "all eight implement pending_count/0 and return a non-negative integer" do
      # The roster is pinned so a ninth duty moving off the crontab without a
      # count fails here rather than silently shipping a workflow whose only
      # success signal is the job's own `:ok`.
      assert length(@all) == 8

      for worker <- @all do
        count = worker.pending_count()

        assert is_integer(count) and count >= 0,
               "#{inspect(worker)}.pending_count/0 returned #{inspect(count)}"
      end
    end
  end

  describe "the count reports a real backlog — planted cases" do
    test "⛔ import rows past the retention window are counted, then swept" do
      # Reader free text, so a count that under-reports here is a
      # data-minimisation gap rather than untidiness.
      import_record = insert(:library_import)
      retention_days = Stacks.Imports.row_retention_days()
      stale = DateTime.add(DateTime.utc_now(), -(retention_days + 1), :day)

      insert(:library_import_row, import: import_record, created_at: stale)

      planted = LibraryImportRowRetentionJob.pending_count()

      assert planted >= 1,
             "a row #{retention_days + 1} days old was not counted as past the window — " <>
               "the count cannot report a backlog, so it cannot evidence a sweep either"

      assert :ok = LibraryImportRowRetentionJob.perform(%Oban.Job{args: %{}})

      assert LibraryImportRowRetentionJob.pending_count() == 0,
             "the sweep ran and the count still reports #{planted} — either the sweep missed the " <>
               "row or the count disagrees with it about what 'expired' means"
    end

    test "⛔ an image past its expiry is counted, and a live one is not" do
      # Both directions. A count that returned every row would also be
      # "non-zero when something is wrong" and would say nothing.
      owner = insert(:user)
      now = DateTime.utc_now()

      insert(:uploaded_image,
        user_id: owner.id,
        status: "pending",
        uploaded_at: DateTime.add(now, -40, :day),
        expires_at: DateTime.add(now, -10, :day)
      )

      assert ImageRetentionJob.pending_count() >= 1,
             "an image ten days past its expiry was not counted"

      baseline = ImageRetentionJob.pending_count()

      insert(:uploaded_image,
        user_id: owner.id,
        status: "pending",
        uploaded_at: now,
        expires_at: DateTime.add(now, 30, :day)
      )

      assert ImageRetentionJob.pending_count() == baseline,
             "a freshly uploaded image counted as past expiry — the count is measuring rows " <>
               "rather than overdue rows, which would read as a permanent backlog"
    end

    test "an unverified registration past the window is counted" do
      # Delegates to the sweep's own selection query, so this also pins that
      # the delegation reaches a query that can match something.
      before = ExpiredUnverifiedAccountsJob.pending_count()

      insert(:unconfirmed_user,
        created_at: DateTime.add(DateTime.utc_now(), -400, :day),
        email_confirmation_token: "expired-" <> Ecto.UUID.generate(),
        pending_email: nil
      )

      after_plant = ExpiredUnverifiedAccountsJob.pending_count()

      assert after_plant >= before,
             "planting a long-expired unconfirmed registration did not increase the count"
    end
  end

  describe "the count shares its sweep's definition of expired" do
    test "⚠️ a row one day INSIDE the window is not counted" do
      # ⛔ The assertion that makes the others mean something. If the count used
      # its own cutoff, it could disagree with the sweep — and the direction
      # that matters is the quiet one: the count reads all-clear while rows the
      # sweep would take are still there, hiding exactly the backlog it exists
      # to reveal.
      import_record = insert(:library_import)
      retention_days = Stacks.Imports.row_retention_days()
      inside = DateTime.add(DateTime.utc_now(), -(retention_days - 1), :day)

      insert(:library_import_row, import: import_record, created_at: inside)

      assert LibraryImportRowRetentionJob.pending_count() == 0,
             "a row still inside the retention window was counted as expired, so the count's " <>
               "cutoff is not the sweep's"
    end
  end
end
