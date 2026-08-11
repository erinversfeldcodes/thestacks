defmodule Stacks.Workers.VisibilityRecapJob do
  @moduledoc """
  Caps stored bookshelf/placement visibility down to a user's new, more
  restrictive `profile_visibility` — one batch update, run async so the
  settings response doesn't block. Read-time enforcement
  (`Visibility.resolve_visibility/2`) already ignores stale stored values,
  so this is stored-state hygiene, not a security fix. Args: `"user_id"`,
  `"new_visibility"`.
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

  defp visibilities_below("owner"), do: ["platform", "group"]
  defp visibilities_below(_), do: []
end
