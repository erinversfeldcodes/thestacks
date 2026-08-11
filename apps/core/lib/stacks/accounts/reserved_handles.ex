defmodule Stacks.Accounts.ReservedHandles do
  @moduledoc """
  Handles a user may NOT claim. Two reasons:

  1. **Every top-level SPA route segment** (`frontend/src/Navigation/Route.elm`)
     plus the `u` profile prefix — so a handle can never be confused with a
     first-class page even if the app ever exposes a bare `/:handle`. Today
     handles live under `/u/:handle` (an Elm route that cannot shadow other SPA
     routes), so this is defence-in-depth, not a hard routing requirement.
  2. **Operational / impersonation-sensitive** words (`admin`, `api`, `support`…).

  All checks are case-insensitive against the lowercased handle.
  """

  @route_segments ~w(
    u login library antilibrary wishlist reading-pile looking-for-home books
    upload search settings costs catalogue marketplace blog admin groups
    confirm-email
  )

  @operational ~w(
    api static assets health me new root about help support terms privacy
    home owner staff moderator system stacks thestacks null undefined
  )

  @all (@route_segments ++ @operational) |> Enum.uniq() |> Enum.sort()

  @doc "The full sorted, de-duplicated reserved-handle list (all lowercase)."
  @spec all() :: [String.t()]
  def all, do: @all

  @doc "Whether `handle` (any case) is reserved."
  @spec reserved?(term()) :: boolean()
  def reserved?(handle) when is_binary(handle), do: String.downcase(handle) in @all
  def reserved?(_), do: false
end
