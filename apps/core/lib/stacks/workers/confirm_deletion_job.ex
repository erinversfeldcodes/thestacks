defmodule Stacks.Workers.ConfirmDeletionJob do
  @moduledoc """
  Oban worker that sends a deletion confirmation to the user (stub).
  In production this would send an email via a mailer.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "email" => email}}) do
    Logger.info(
      "ConfirmDeletionJob: sending deletion confirmation to #{email} for user #{user_id} (stub)"
    )

    :ok
  end

  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Logger.info("ConfirmDeletionJob: sending deletion confirmation for user #{user_id} (stub)")
    :ok
  end
end
