defmodule Stacks.Workers.EmailDeliveryJob do
  @moduledoc """
  Oban worker that delivers transactional emails via Swoosh.

  Checks user notification preferences before sending, except for
  transactional emails that must always be delivered regardless of prefs.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Core.Repo
  alias Stacks.Accounts.User
  alias Stacks.Email.Mailer
  alias Stacks.Email.Templates

  # All known email templates. Any job with an unrecognised template is discarded
  # immediately (no retries) to prevent blocking the queue.
  @known_templates %{
    "registration_confirmation" => :registration_confirmation,
    "password_reset" => :password_reset,
    "marketplace_sale" => :marketplace_sale,
    "gdpr_export_ready" => :gdpr_export_ready,
    "wishlist_availability" => :wishlist_availability,
    "opt_out_confirmation" => :opt_out_confirmation
  }

  # Templates that bypass user notification preferences
  @bypass_prefs [
    :registration_confirmation,
    :password_reset,
    :gdpr_export_ready,
    :opt_out_confirmation
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"template" => template_str, "user_id" => user_id, "params" => params}
      }) do
    case Map.fetch(@known_templates, template_str) do
      :error ->
        {:discard, "unknown email template: #{template_str}"}

      {:ok, template} ->
        deliver(template, user_id, params)
    end
  end

  defp deliver(template, user_id, params) do
    user = Repo.get!(User, user_id)

    if should_send?(user, template) do
      email = build_email(user, template, params)

      case Mailer.deliver(email) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp should_send?(_user, template) when template in @bypass_prefs, do: true
  defp should_send?(user, :wishlist_availability), do: user.notify_wishlist_availability
  defp should_send?(user, :marketplace_sale), do: user.notify_marketplace
  # Unknown templates default to false — new opt-in notifications must be
  # explicitly listed above to avoid sending unintended emails.
  defp should_send?(_user, _template), do: false

  defp build_email(user, :registration_confirmation, %{"token" => token}) do
    base_url = CoreWeb.Endpoint.url()
    confirmation_url = base_url <> "/api/auth/confirm/#{token}"

    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from({"The Stacks", "noreply@thestacks.app"})
    |> Swoosh.Email.subject("Confirm your email — The Stacks")
    |> Swoosh.Email.html_body(Templates.registration_confirmation(confirmation_url))
  end

  defp build_email(user, :password_reset, %{"token" => token}) do
    base_url = CoreWeb.Endpoint.url()
    reset_url = base_url <> "/reset-password/#{token}"

    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from({"The Stacks", "noreply@thestacks.app"})
    |> Swoosh.Email.subject("Reset your password — The Stacks")
    |> Swoosh.Email.html_body(Templates.password_reset(reset_url))
  end

  defp build_email(user, :marketplace_sale, %{"role" => role, "book_title" => book_title}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from({"The Stacks", "noreply@thestacks.app"})
    |> Swoosh.Email.subject("Book transaction update — The Stacks")
    |> Swoosh.Email.html_body(Templates.marketplace_sale(role, book_title))
  end

  defp build_email(user, :gdpr_export_ready, %{"download_url" => download_url}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from({"The Stacks", "noreply@thestacks.app"})
    |> Swoosh.Email.subject("Your data export is ready — The Stacks")
    |> Swoosh.Email.html_body(Templates.gdpr_export_ready(download_url))
  end

  defp build_email(user, :wishlist_availability, %{"book_title" => book_title}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from({"The Stacks", "noreply@thestacks.app"})
    |> Swoosh.Email.subject("A book on your WishList is available — The Stacks")
    |> Swoosh.Email.html_body(Templates.wishlist_availability(book_title))
  end

  defp build_email(user, :opt_out_confirmation, _params) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from({"The Stacks", "noreply@thestacks.app"})
    |> Swoosh.Email.subject("Removal request received — The Stacks")
    |> Swoosh.Email.html_body(Templates.opt_out_confirmation())
  end
end
