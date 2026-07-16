defmodule StacksWeb.OnboardingController do
  @moduledoc """
  Handles onboarding step tracking endpoints.

  - GET  /api/onboarding/status      — returns current step completion map
  - PUT  /api/onboarding/step/:step  — marks a step as complete
  - POST /api/onboarding/reset       — resets all steps (for re-entry from Settings)
  """

  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias StacksWeb.ProtoJSON

  @doc "GET /api/onboarding/status — return current onboarding completion state."
  def status(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    status = Accounts.onboarding_status(user.id)
    json(conn, ProtoJSON.onboarding_status(status))
  end

  @doc "PUT /api/onboarding/step/:step — mark a step as complete."
  def complete_step(conn, %{"step" => step}) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.complete_onboarding_step(user.id, step) do
      {:ok, _user} ->
        status = Accounts.onboarding_status(user.id)
        json(conn, ProtoJSON.onboarding_status(status))

      {:error, :invalid_step} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid_step", valid_steps: Accounts.onboarding_step_order()})
    end
  end

  @doc "POST /api/onboarding/reset — reset all steps to allow re-entry from Settings."
  def reset(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.reset_onboarding(user.id) do
      {:ok, _user} ->
        status = Accounts.onboarding_status(user.id)
        json(conn, ProtoJSON.onboarding_status(status))

      {:error, _changeset} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "reset failed"})
    end
  end
end
