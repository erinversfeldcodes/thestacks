defmodule Stacks.Accounts.AuthTokenFamily do
  @moduledoc """
  A refresh-token *family*: one rotation chain per session (Issue #179).

  Opened at login and updated on every refresh rotation. `current_jti` tracks
  the family's single live access token; a later phase uses it to detect reuse
  of a superseded token and revoke the whole family (`revoked_at`).

  `family_id` is application-supplied (login generates it before minting the
  JWT so the same value can be embedded as a claim), hence `autogenerate: false`.
  This is a hand-written schema — the table has no `.proto` contract.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:family_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @type t :: %__MODULE__{}

  schema "auth_token_families" do
    field :user_id, :binary_id
    field :current_jti, :string
    field :session_started_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @castable [:family_id, :user_id, :current_jti, :session_started_at, :revoked_at]
  @required [:family_id, :user_id, :current_jti, :session_started_at]

  @doc "Changeset for opening or updating a token family."
  def changeset(family, attrs) do
    family
    |> cast(attrs, @castable)
    |> validate_required(@required)
  end
end
