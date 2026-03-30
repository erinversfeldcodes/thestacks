defmodule StacksWeb.PartnerRegistrationController do
  @moduledoc "Public partner self-registration endpoint."

  use CoreWeb, :controller

  alias Stacks.Partners
  alias StacksWeb.ProtoJSON

  action_fallback CoreWeb.FallbackController

  def create(conn, params) do
    case Partners.register_partner(params) do
      {:ok, partner} ->
        conn
        |> put_status(:created)
        |> json(%{partner: ProtoJSON.partner(partner)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
