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
  # domain is verified in Resend, then flip to noreply@ the canonical domain. Overridable
  # at runtime via the EMAIL_FROM env var (see config/runtime.exs).
  defp from_address do
    default_domain = Application.get_env(:core, :canonical_domain, "readinginthestacks.com")
    Application.get_env(:core, :email_from, {"The Stacks", "noreply@#{default_domain}"})
  end

  # Recipient for a transactional email.
  #
  # TEMPORARY STOPGAP (see the matching TODO(email) in config/config.exs): while the
  # sender is Resend's `onboarding@resend.dev` test address, Resend 403s any recipient
  # carrying a display name (a `{name, addr}` "to") and only accepts a bare address to
  # the Resend-account owner. So we send to the bare `user.email` while onboarding mode
  # is active, and restore the `{display_name, email}` tuple automatically once the
  # sender is a verified domain (i.e. `:email_from` no longer points at onboarding).
  defp recipient(user) do
    case from_address() do
      {_name, "onboarding@resend.dev"} -> user.email
      "onboarding@resend.dev" -> user.email
      _ -> {user.display_name || user.email, user.email}
    end
  end

  @known_templates %{
    "registration_confirmation" => :registration_confirmation,
    "password_reset" => :password_reset,
    "email_change_confirmation" => :email_change_confirmation,
    "email_change_notice" => :email_change_notice,
    "marketplace_sale" => :marketplace_sale,
    "gdpr_export_ready" => :gdpr_export_ready,
    "wishlist_availability" => :wishlist_availability,
    "opt_out_confirmation" => :opt_out_confirmation,
    "group_invitation" => :group_invitation,
    "new_offer" => :new_offer,
    "wishlist_available" => :wishlist_available
  }

  @bypass_prefs [
    :registration_confirmation,
    :password_reset,
    :email_change_confirmation,
    :email_change_notice,
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

    cond do
      stale_email_change?(user, template, params) ->
        {:discard, "email change already settled or superseded — its #{template} is a dead link"}

      should_send?(user, template) ->
        send_email(user, template, params)

      true ->
        :ok
    end
  end

  # An email change can be confirmed, undone, or re-requested between enqueue and
  # delivery. In all three the row no longer holds this job's token, and the link
  # in the email would resolve to nothing — so the job is dropped rather than
  # delivering a letter whose only affordance is already dead.
  defp stale_email_change?(user, :email_change_confirmation, %{"token" => token}),
    do: user.pending_email_token != token

  defp stale_email_change?(user, :email_change_notice, %{"token" => token}),
    do: user.pending_email_revert_token != token

  defp stale_email_change?(_user, _template, _params), do: false

  defp send_email(user, template, params) do
    email = build_email(user, template, params)

    case Mailer.deliver(email) do
      {:ok, _} ->
        # The billable unit for the email provider, counted where it actually
        # happens. The cost page previously derived its send count from rows in
        # `oban_jobs`, which the pruner deletes about a minute after the job
        # finishes — so a "this month" figure only ever saw the last minute.
        # The template is a bounded set (`@known_templates`), so it is safe as a
        # label; no address, name or user id is attached.
        :telemetry.execute([:stacks, :email, :delivered], %{count: 1}, %{template: template})
        :ok

      {:error, reason} ->
        # feeds the :resend_fuse state gauge — delivery failures are the
        # only real-traffic signal that the email provider is down
        Stacks.CircuitBreakers.melt(:resend_fuse)
        {:error, reason}
    end
  end

  defp should_send?(_user, template) when template in @bypass_prefs, do: true
  defp should_send?(user, :wishlist_availability), do: user.notify_wishlist_availability
  defp should_send?(user, :wishlist_available), do: user.notify_wishlist_availability
  defp should_send?(user, :marketplace_sale), do: user.notify_marketplace
  defp should_send?(user, :new_offer), do: user.notify_marketplace
  defp should_send?(user, :group_invitation), do: user.notify_group_invitations
  defp should_send?(_user, _template), do: false

  defp build_email(user, :registration_confirmation, %{"token" => token}) do
    base_url = CoreWeb.Endpoint.url()
    confirmation_url = base_url <> "/api/auth/confirm/#{token}"

    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient(user))
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Confirm your email — The Stacks")
    |> Swoosh.Email.html_body(Templates.registration_confirmation(confirmation_url))
  end

  defp build_email(user, :password_reset, %{"token" => token}) do
    base_url = CoreWeb.Endpoint.url()
    reset_url = base_url <> "/reset-password/#{token}"

    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient(user))
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Reset your password — The Stacks")
    |> Swoosh.Email.html_body(Templates.password_reset(reset_url))
  end

  defp build_email(user, :email_change_confirmation, %{"token" => token}) do
    confirmation_url = CoreWeb.Endpoint.url() <> "/api/auth/confirm-email-change/#{token}"

    # The one email in this system NOT addressed to the account's own address:
    # it is asking an address that is not yet the account's to prove it can read.
    Swoosh.Email.new()
    |> Swoosh.Email.to(user.pending_email)
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Confirm your new email address — The Stacks")
    |> Swoosh.Email.html_body(Templates.email_change_confirmation(confirmation_url))
  end

  defp build_email(user, :email_change_notice, %{"token" => token}) do
    revert_url = CoreWeb.Endpoint.url() <> "/api/auth/revert-email-change/#{token}"

    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient(user))
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Your email address is being changed — The Stacks")
    |> Swoosh.Email.html_body(Templates.email_change_notice(user.pending_email, revert_url))
  end

  defp build_email(user, :marketplace_sale, %{"role" => role, "book_title" => book_title}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient(user))
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Book transaction update — The Stacks")
    |> Swoosh.Email.html_body(Templates.marketplace_sale(role, book_title))
  end

  defp build_email(user, :gdpr_export_ready, %{"download_url" => download_url} = params) do
    expires_in_seconds = Map.get(params, "expires_in_seconds", 86_400)

    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient(user))
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("Your data export is ready — The Stacks")
    |> Swoosh.Email.html_body(Templates.gdpr_export_ready(download_url, expires_in_seconds))
  end

  defp build_email(user, :wishlist_availability, %{"book_title" => book_title}) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient(user))
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("A book on your WishList is available — The Stacks")
    |> Swoosh.Email.html_body(Templates.wishlist_availability(book_title))
  end

  defp build_email(user, :opt_out_confirmation, _params) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient(user))
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
    |> Swoosh.Email.to(recipient(user))
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
    |> Swoosh.Email.to(recipient(user))
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
    |> Swoosh.Email.to(recipient(user))
    |> Swoosh.Email.from(from_address())
    |> Swoosh.Email.subject("A book on your WishList is available — The Stacks")
    |> Swoosh.Email.html_body(
      Templates.wishlist_available(book_title, author_name, price_zar, seller_name)
    )
  end
end
