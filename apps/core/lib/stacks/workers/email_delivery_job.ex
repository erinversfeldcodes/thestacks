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

  # ⚠️ The token is resolved from the USER ROW, never from the job args.
  #
  # `oban_jobs.args` is an ordinary queryable table with no erasure path and,
  # since the pruner window went from 60 seconds to 7 days, a long memory. A
  # password-reset or confirmation token sitting there is a live credential:
  # the reset token verifies for 24 hours (`Email.reset_password/2`'s
  # `max_age: 86_400`) and the confirmation tokens are compared straight
  # against the user row with no expiry at all, so they are usable until
  # consumed.
  #
  # The job only ever needs to know WHICH user, and it already loads that row.
  # What it cannot get from the row is whether its own enqueue has been
  # superseded — so the args carry a SHA-256 digest of the token instead, which
  # answers that question and is useless to anyone reading the table.
  defp deliver(template, user_id, params) do
    user = Repo.get!(User, user_id)

    cond do
      # ⚠️ Staleness is judged against the ARGS AS ENQUEUED, before any token is
      # resolved. Injecting the live token first — which an earlier version of
      # this function did — overwrites the only thing that distinguishes this
      # job's enqueue from the current state, so the comparison becomes the
      # live token against itself and nothing is ever stale. The test for a
      # superseded change is what caught it.
      stale_email_change?(user, template, params) ->
        {:discard, "email change already settled or superseded — its #{template} is a dead link"}

      should_send?(user, template) ->
        send_email(user, template, with_live_token(user, template, params))

      true ->
        :ok
    end
  end

  defp with_live_token(user, template, params) do
    case live_token(user, template) do
      nil -> params
      token -> Map.put(params, "token", token)
    end
  end

  # An email change can be confirmed, undone, or re-requested between enqueue and
  # delivery. In all three the row no longer holds this job's token, and the link
  # in the email would resolve to nothing — so the job is dropped rather than
  # delivering a letter whose only affordance is already dead.
  defp stale_email_change?(user, :email_change_confirmation, %{"token_digest" => digest}),
    do: digest_of(user.pending_email_token) != digest

  defp stale_email_change?(user, :email_change_notice, %{"token_digest" => digest}),
    do: digest_of(user.pending_email_revert_token) != digest

  # ⚠️ Jobs enqueued BEFORE this change carry the raw token, and the digest
  # clauses above do not match them. Without this pair they would fall through
  # to the catch-all, be judged "not stale", and deliver a dead link — the
  # staleness gate silently skipped for exactly the jobs in flight across the
  # deploy. The 7-day pruner window makes that population larger, not smaller.
  #
  # Remove after one release, once no `"token"`-shaped job can still be
  # retrying.
  defp stale_email_change?(user, :email_change_confirmation, %{"token" => token}),
    do: user.pending_email_token != token

  defp stale_email_change?(user, :email_change_notice, %{"token" => token}),
    do: user.pending_email_revert_token != token

  defp stale_email_change?(_user, _template, _params), do: false

  # The token that is live for this user and template RIGHT NOW. Read at
  # delivery time rather than carried through the queue.
  defp live_token(user, :registration_confirmation), do: user.email_confirmation_token
  defp live_token(user, :password_reset), do: user.password_reset_token
  defp live_token(user, :email_change_confirmation), do: user.pending_email_token
  defp live_token(user, :email_change_notice), do: user.pending_email_revert_token
  # Most templates carry no credential at all — marketplace, wishlist and
  # export notifications address the user, they do not authorise anything.
  defp live_token(_user, _template), do: nil

  @doc false
  @spec digest_of(binary() | nil) :: binary() | nil
  def digest_of(nil), do: nil

  def digest_of(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

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
