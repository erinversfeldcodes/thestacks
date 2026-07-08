defmodule Stacks.Accounts.Guardian do
  @moduledoc """
  Guardian implementation for JWT-based authentication.

  Supports two token types:
  - Standard user tokens (default `typ`)
  - Admin tokens (`typ: "admin_session"`) with additional `sid` (session_id) and
    `bid` (boot_id) claims. Admin tokens are rejected if the boot_id does not
    match the current application boot.
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

  @impl true
  def build_claims(claims, _resource, opts) do
    if Keyword.get(opts, :token_type) == "admin" do
      {:ok,
       Map.merge(claims, %{
         "typ" => "admin_session",
         "sid" => Keyword.fetch!(opts, :session_id),
         "bid" => Keyword.fetch!(opts, :boot_id)
       })}
    else
      {:ok, claims}
    end
  end

  @impl true
  def verify_claims(claims, opts) do
    if claims["typ"] == "admin_session" do
      if claims["bid"] == Core.Application.boot_id() do
        super(claims, opts)
      else
        {:error, :invalid_boot_id}
      end
    else
      {:ok, claims}
    end
  end
end
