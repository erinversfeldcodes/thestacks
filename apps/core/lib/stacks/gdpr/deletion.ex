defmodule Stacks.GDPR.Deletion do
  @moduledoc """
  GDPR right-to-erasure. Deletes user data from the operational schema,
  anonymises any downstream records, and scrubs PII from event_log payloads.

  All operations run in a single `Ecto.Multi` transaction to ensure atomicity.
  A deletion record is inserted into the audit_log after all data is removed.
  """

  # Ecto.Multi uses an opaque MapSet internally; dialyzer cannot resolve the
  # opaque subterms after Multi.new() and fires call_without_opaque on every
  # chained call. This is a known false positive.
  @dialyzer :no_opaque

  import Ecto.Query

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.User
  alias Stacks.Audit
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}

  @doc """
  Deletes all operational data for a user and scrubs PII from the event_log.
  Returns `{:ok, map()}` on success.
  """
  @spec delete_user_data(binary()) :: {:ok, map()} | {:error, atom(), term(), map()}
  def delete_user_data(user_id) do
    Multi.new()
    |> Multi.run(:bookshelves, fn repo, _ ->
      bookshelves = repo.all(from bs in Bookshelf, where: bs.user_id == ^user_id)
      {:ok, bookshelves}
    end)
    |> Multi.run(:bookshelf_ids, fn _repo, %{bookshelves: bookshelves} ->
      {:ok, Enum.map(bookshelves, & &1.id)}
    end)
    |> Multi.run(:placement_ids, fn repo, %{bookshelf_ids: bookshelf_ids} ->
      ids = repo.all(from p in Placement, where: p.bookshelf_id in ^bookshelf_ids, select: p.id)
      {:ok, ids}
    end)
    |> Multi.run(:delete_history, fn repo, %{bookshelf_ids: bookshelf_ids} ->
      # PlacementHistory has from_bookshelf/to_bookshelf UUIDs, not placement_id
      {count, _} =
        repo.delete_all(
          from h in PlacementHistory,
            where: h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids
        )

      {:ok, count}
    end)
    |> Multi.run(:delete_placements, fn repo, %{bookshelf_ids: bookshelf_ids} ->
      {count, _} = repo.delete_all(from p in Placement, where: p.bookshelf_id in ^bookshelf_ids)
      {:ok, count}
    end)
    |> Multi.run(:delete_bookshelves, fn repo, _ ->
      {count, _} = repo.delete_all(from bs in Bookshelf, where: bs.user_id == ^user_id)
      {:ok, count}
    end)
    |> Multi.run(:scrub_events, fn repo, _ ->
      {:ok, user_id_bin} = Ecto.UUID.dump(user_id)

      {count, _} =
        repo.update_all(
          from(e in "event_log",
            prefix: "op",
            where: e.aggregate_type == "user" and e.aggregate_id == ^user_id_bin
          ),
          set: [payload: %{}, metadata: %{"scrubbed" => true}]
        )

      {:ok, count}
    end)
    |> Multi.run(:delete_user, fn repo, _ ->
      case repo.get(User, user_id) do
        nil -> {:error, :user_not_found}
        user -> repo.delete(user)
      end
    end)
    |> Multi.run(:audit, fn _repo, _ ->
      Audit.log(nil, "user.data_deleted", resource_type: "user", resource_id: user_id)
    end)
    |> Repo.transaction()
  end
end
