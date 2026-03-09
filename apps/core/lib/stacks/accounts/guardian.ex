defmodule Stacks.Accounts.Guardian do
  @moduledoc """
  Guardian implementation for JWT-based authentication.
  """

  use Guardian, otp_app: :core

  alias Stacks.Accounts

  @impl true
  def subject_for_token(user, _claims) do
    {:ok, to_string(user.id)}
  end

  @impl true
  def resource_from_claims(%{"sub" => id}) do
    case Accounts.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
    end
  end

  def resource_from_claims(_), do: {:error, :invalid_claims}
end
