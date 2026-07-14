defmodule Stacks.Workers.VisibilityRecapJob do
  @moduledoc """
  Oban worker that caps bookshelf and placement visibility down to match a
  user's new (more restrictive) profile_visibility setting.

  When a user changes profile_visibility to "owner", any bookshelves or
  placements stored as "platform" or "group" violate the new ceiling and are
  updated in a single batch. The visibility_level enum is (group, platform, owner);
  there is no "public" value. This runs asynchronously so it does not block
  the HTTP response for the settings change.

  The visibility change is already enforced at read time by
  `Stacks.Visibility.resolve_visibility/2` regardless of stored values, so
  stale stored visibility is a correctness-of-stored-state issue, not a
  security issue. This job brings stored values into sync.

  Args:
    - `"user_id"` — the user whose resources should be recapped
    - `"new_visibility"` — the new profile_visibility value ("owner" or "platform")
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Blog
  alias Stacks.Events
  alias Stacks.Shelving.Bookshelf
  alias Stacks.Shelving.Placement

  @impl true
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "new_visibility" => new_visibility}
      }) do
    violating = visibilities_below(new_visibility)

    if violating == [] do
      Logger.info(
        "VisibilityRecapJob: no recap needed for user #{user_id} (ceiling: #{new_visibility})"
      )

      :telemetry.execute(
        [:stacks, :visibility, :recap],
        %{bookshelves_capped: 0, placements_capped: 0, posts_capped: 0},
        %{outcome: :noop}
      )

      :ok
    else
      now = DateTime.utc_now()

      {bookshelf_count, _} =
        Bookshelf
        |> where([b], b.user_id == ^user_id and b.visibility in ^violating)
        |> Repo.update_all(set: [visibility: new_visibility, updated_at: now])

      {placement_count, _} =
        Placement
        |> join(:inner, [p], b in Bookshelf, on: p.bookshelf_id == b.id)
        |> where([p, b], b.user_id == ^user_id and p.visibility in ^violating)
        |> Repo.update_all(set: [visibility: new_visibility, updated_at: now])

      {:ok, posts_capped} = Blog.tighten_posts_to_ceiling(user_id, new_visibility)

      Logger.info(
        "VisibilityRecapJob: capped #{bookshelf_count} bookshelves, " <>
          "#{placement_count} placements, and #{posts_capped} posts " <>
          "for user #{user_id} → #{new_visibility}"
      )

      :telemetry.execute(
        [:stacks, :visibility, :recap],
        %{
          bookshelves_capped: bookshelf_count,
          placements_capped: placement_count,
          posts_capped: posts_capped
        },
        %{outcome: :capped}
      )

      Events.emit_safe(%{
        event_type: "user.visibility_recap_completed",
        aggregate_type: "user",
        aggregate_id: user_id,
        payload: %{
          new_visibility: new_visibility,
          bookshelves_capped: bookshelf_count,
          placements_capped: placement_count,
          posts_capped: posts_capped
        }
      })

      :ok
    end
  rescue
    exception ->
      Logger.error(
        "VisibilityRecapJob: unhandled exception for user #{user_id}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :telemetry.execute(
        [:stacks, :visibility, :recap],
        %{bookshelves_capped: 0, placements_capped: 0, posts_capped: 0},
        %{outcome: :error}
      )

      {:error, exception}
  end

  # Returns the visibility values that are less restrictive (more permissive)
  # than the given ceiling and therefore need to be capped down.
  #
  # Visibility rank: "group" (0) < "platform" (1) < "owner" (2).
  # The visibility_level enum only has: owner, group, platform.
  defp visibilities_below("owner"), do: ["platform", "group"]
  defp visibilities_below(_), do: []
end
