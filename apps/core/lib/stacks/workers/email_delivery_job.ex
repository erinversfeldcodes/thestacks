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

  # Sender for all transactional email. Configurable (`:email_from`) so we can
  # use Resend's `onboarding@resend.dev` test sender until the `thestacks.app`
  # domain is verified in Resend, then flip to `noreply@thestacks.app`. Overridable
  # at runtime via the EMAIL_FROM env var (see config/runtime.exs).
  defp from_address do
    Application.get_env(:core, :email_from, {"The Stacks", "noreply@thestacks.app"})
  end

  # All known email templates. Any job with an unrecognised template is discarded
  # immediately (no retries) to prevent blocking the queue.
  @known_templates %{
    "registration_confirmation" => :registration_confirmation,
    "password_reset" => :password_reset,
    "marketplace_sale" => :marketplace_sale,
    "gdpr_export_ready" => :gdpr_export_ready,
    "wishlist_availability" => :wishlist_availability,
    "opt_out_confirmation" => :opt_out_confirmation,
    "group_invitation" => :group_invitation,
    "new_offer" => :new_offer,
    "wishlist_available" => :wishlist_available
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
  defp should_send?(user, :wishlist_available), do: user.notify_wishlist_availability
  defp should_send?(user, :marketplace_sale), do: user.notify_marketplace
  defp should_send?(user, :new_offer), do: user.notify_marketplace
  defp should_send?(user, :group_invitation), do: user.notify_group_invitations
  # Unknown templates default to false — new opt-in notifications must be
  # explicitly listed above to avoid sending unintended emails.
  defp should_send?(_user, _template), do: false

  defp build_email(user, :registration_confirmation, %{"token" => token}) do
    base_url = CoreWeb.Endpoint.url()
    confirmation_url = base_url <> "/api/auth/confirm/#{token}"

    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Confirm your email — The Stacks")
    |> Swoosh.Email.html_body(Templates.registration_confirmation(confirmation_url))
  end

  defp build_email(user, :password_reset, %{"token" => token}) do
    base_url = CoreWeb.Endpoint.url()
    reset_url = base_url <> "/reset-password/#{token}"

    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Reset your password — The Stacks")
    |> Swoosh.Email.html_body(Templates.password_reset(reset_url))
  end

  defp build_email(user, :marketplace_sale, %{"role" => role, "book_title" => book_title}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Book transaction update — The Stacks")
    |> Swoosh.Email.html_body(Templates.marketplace_sale(role, book_title))
  end

  defp build_email(user, :gdpr_export_ready, %{"download_url" => download_url}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Your data export is ready — The Stacks")
    |> Swoosh.Email.html_body(Templates.gdpr_export_ready(download_url))
  end

  defp build_email(user, :wishlist_availability, %{"book_title" => book_title}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("A book on your WishList is available — The Stacks")
    |> Swoosh.Email.html_body(Templates.wishlist_availability(book_title))
  end

  defp build_email(user, :opt_out_confirmation, _params) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Removal request received — The Stacks")
    |> Swoosh.Email.html_body(Templates.opt_out_confirmation())
  end

  defp build_email(user, :group_invitation, %{
         "inviter_name" => inviter_name,
         "group_name" => group_name,
         "accept_url" => accept_url
       }) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("You've been invited to a group — The Stacks")
    |> Swoosh.Email.html_body(Templates.group_invitation(inviter_name, group_name, accept_url))
  end

  defp build_email(user, :new_offer, %{
         "buyer_name" => buyer_name,
         "listing_title" => listing_title,
         "offer_amount_zar" => offer_amount_zar,
         "offer_url" => offer_url
       }) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("New offer on your listing — The Stacks")
    |> Swoosh.Email.html_body(
      Templates.new_offer(buyer_name, listing_title, offer_amount_zar, offer_url)
    )
  end

  defp build_email(user, :wishlist_available, %{
         "book_title" => book_title,
         "author_name" => author_name,
         "price_zar" => price_zar,
         "seller_name" => seller_name
       }) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({user.display_name || user.email, user.email})
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("A book on your WishList is available — The Stacks")
    |> Swoosh.Email.html_body(
      Templates.wishlist_available(book_title, author_name, price_zar, seller_name)
    )
  end
end
