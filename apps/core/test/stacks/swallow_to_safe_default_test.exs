defmodule Stacks.SwallowToSafeDefaultTest do
  @moduledoc """
      Two rescue clauses, each of which has never been executed by a test.

      Both are on a READ path and both exist so that one unreadable thing does
      not take down the request that happened to touch it. That makes them the
      kind of code where a regression is invisible: delete the rescue and
      everything stays green until the day the bad input actually arrives,
      which is the day you least want to discover it. Neither site is dead
      code — they are insurance whose premium nobody had checked.

      The two are together because they share that shape, not a subject.

      ## Why `transparency_test.exs`'s "graceful degradation" does not cover this

      That describe degrades the **Prometheus client** —
      `MockPrometheusClient.put_response({:error, …})` — which exercises the
      error path *through* the cache and never removes the ETS table. The
      `ArgumentError` rescue in `safe_lookup/1` only fires when the table is
      absent, which happens before the owning GenServer has initialised or
      after it has gone down. Reaching it needs the child actually stopped.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Audit
  alias Stacks.Transparency.Cache

  describe "an audit row whose metadata cannot be read still lists" do
    # `decrypt_metadata/1` is private and reached only through
    # `list_for_user/2`, which is the honest way to drive it: the invariant is
    # about what a reader sees, not about the helper in isolation.
    defp insert_audit_row(user_id, metadata) do
      Core.Repo.insert_all(
        "audit_log",
        [
          %{
            id: Ecto.UUID.dump!(Ecto.UUID.generate()),
            user_id: Ecto.UUID.dump!(user_id),
            action: "user.login",
            resource_type: "user",
            resource_id: Ecto.UUID.dump!(user_id),
            ip_address: nil,
            metadata: metadata,
            occurred_at: DateTime.utc_now()
          }
        ],
        prefix: "audit"
      )
    end

    test "nil, undecryptable, and valid-ciphertext-over-non-JSON all read as an empty map" do
      user = insert(:user)

      # A good row alongside the bad ones. Without it a listing that returned
      # nothing at all would satisfy every "reads as %{}" assertion below by
      # vacuously having no rows to check — and that is the actual failure this
      # guards: one unreadable row taking the whole listing with it.
      good = %{"ok" => true}
      insert_audit_row(user.id, good |> Jason.encode!() |> Stacks.Vault.encrypt!())

      insert_audit_row(user.id, nil)
      insert_audit_row(user.id, :crypto.strong_rand_bytes(48))
      insert_audit_row(user.id, Stacks.Vault.encrypt!("this is not json at all"))

      {entries, total, _page, _per_page} = Audit.list_for_user(user.id)

      assert total == 4,
             "expected all four rows to be listed; got #{total}. A row whose metadata " <>
               "cannot be decoded must still appear — it is the record that something " <>
               "happened, and the metadata is the least important part of it."

      metadatas = Enum.map(entries, & &1.metadata)

      assert good in metadatas,
             "the readable row's metadata did not survive the listing, so this test is " <>
               "asserting that everything decodes to %{} — including the row that should " <>
               "have decoded properly"

      assert Enum.count(metadatas, &(&1 == %{})) == 3,
             "expected exactly three unreadable rows to read as %{}; got " <>
               "#{inspect(metadatas)}. Either a bad row raised, or one of them decoded to " <>
               "something that is not the documented empty value."
    end
  end

  describe "a transparency cache lookup with no table is a miss, not a crash" do
    setup do
      # Deterministically absent, rather than deleting the table underneath its
      # owner: terminate_child stops the GenServer (taking its ETS table with
      # it, as tables die with their owner) and does NOT restart it, so the
      # assertions run against a genuinely absent table. restart_child puts it
      # back for everything that follows.
      #
      # async: false on this module for exactly this reason — the table is
      # process-global, so a concurrent test reading the cache during this one
      # would see the absence too.
      :ok = Supervisor.terminate_child(Core.Supervisor, Cache)

      on_exit(fn ->
        {:ok, _pid} = Supervisor.restart_child(Core.Supervisor, Cache)
      end)

      :ok
    end

    test "get, get_stale and invalidate_all are inert while the table is gone" do
      refute :ets.whereis(:transparency_cache) != :undefined,
             "precondition: the cache table is still present, so none of the rescue clauses " <>
               "below can be reached and this test proves nothing"

      assert Cache.get(:live_signals, 45_000) == :miss,
             "a lookup against an absent table did not report a miss. If it raised, every " <>
               "request touching the transparency page during a cache restart becomes a 500."

      assert Cache.get_stale(:live_signals) == :miss,
             "a stale-read against an absent table did not report a miss"

      assert Cache.invalidate_all() == :ok,
             "invalidating an absent table did not return :ok"
    end

    test "put against an absent table does not raise and does not resurrect it" do
      assert Cache.put(:live_signals, [%{key: :whatever}]) == :ok,
             "writing to an absent table raised instead of being inert. The write path is " <>
               "reached from the same request as the read, so a raise here is the same 500."

      refute :ets.whereis(:transparency_cache) != :undefined,
             "the put recreated the ETS table from the calling process. That would make the " <>
               "table owned by whoever happened to write first and die with them, which is " <>
               "a worse failure than the miss it was avoiding."
    end
  end
end
