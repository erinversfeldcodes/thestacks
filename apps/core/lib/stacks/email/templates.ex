defmodule Stacks.Email.Templates do
  @moduledoc "HTML email templates for transactional emails."

  alias Stacks.Accounts

  @doc "Confirmation email sent after registration."
  def registration_confirmation(confirmation_url) do
    expiry_hours = div(Accounts.unverified_account_ttl_seconds(), 3600)

    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">Confirm your email</h1>
        <p>Welcome to The Stacks. Please confirm your email address to activate your account.</p>
        <p>
          <a href="#{confirmation_url}"
             style="background: #2c1810; color: #f5f0e8; padding: 12px 24px; text-decoration: none; display: inline-block;">
            Confirm email
          </a>
        </p>
        <p style="font-size: 12px; color: #7a6b5d;">
          This link expires in #{expiry_hours} hours. If you did not register, you can safely ignore this email.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc """
      Sent to the address an account is asking to move TO. Until this link is
      clicked the account still answers on its old address — so the copy has to say
      what is waiting on this click, not congratulate anyone on a change that has
      not happened.
  """
  def email_change_confirmation(confirmation_url) do
    expiry_days = div(Accounts.email_change_grace_seconds(), 86_400)

    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">Confirm your new email address</h1>
        <p>Someone asked to move a Stacks account to this address. Until you confirm,
           the account keeps using its old address.</p>
        <p>
          <a href="#{confirmation_url}"
             style="background: #2c1810; color: #f5f0e8; padding: 12px 24px; text-decoration: none; display: inline-block;">
            Confirm this address
          </a>
        </p>
        <p style="font-size: 12px; color: #7a6b5d;">
          This link expires in #{expiry_days} days. If you were not expecting it, you can
          safely ignore this email — the account will simply keep the address it has.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc """
      Sent to the address an account is asking to move AWAY from — the one letter
      in this flow whose reader might be the person the change is being done to.
      It names the address, offers the undo, and says plainly what happens if the
      reader does nothing, because "you'll be signed out in a week" is not a
      detail to discover afterwards.
  """
  def email_change_notice(pending_email, revert_url) do
    expiry_days = div(Accounts.email_change_grace_seconds(), 86_400)

    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">Your email address is being changed</h1>
        <p>A request was made to change this Stacks account's email address to
           <strong>#{Plug.HTML.html_escape(pending_email)}</strong>. We have asked that address
           to confirm itself. Nothing has changed yet.</p>
        <p><strong>If this wasn't you</strong>, undo it now. That cancels the change, signs
           out every device currently signed in, and leaves your address as it is — then
           change your password.</p>
        <p>
          <a href="#{revert_url}"
             style="background: #2c1810; color: #f5f0e8; padding: 12px 24px; text-decoration: none; display: inline-block;">
            This wasn't me — undo it
          </a>
        </p>
        <p style="font-size: 12px; color: #7a6b5d;">
          If neither address answers within #{expiry_days} days, the account will be signed
          out and stay locked until an address is confirmed — this link will still work, and
          will be the way back in. Keep this email until the change is settled.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc "Password reset email."
  def password_reset(reset_url) do
    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">Reset your password</h1>
        <p>We received a request to reset the password for your Stacks account.</p>
        <p>
          <a href="#{reset_url}"
             style="background: #2c1810; color: #f5f0e8; padding: 12px 24px; text-decoration: none; display: inline-block;">
            Reset password
          </a>
        </p>
        <p style="font-size: 12px; color: #7a6b5d;">
          This link expires in 24 hours. If you did not request a password reset, you can safely ignore this email.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc "Marketplace sale notification — role is:seller or:buyer."
  def marketplace_sale(role, book_title) do
    message =
      case role do
        "seller" -> "Your copy of <em>#{book_title}</em> has been sold."
        "buyer" -> "Your purchase of <em>#{book_title}</em> has been confirmed."
        _ -> "A transaction for <em>#{book_title}</em> has been updated."
      end

    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">Book transaction update</h1>
        <p>#{message}</p>
        <p style="font-size: 12px; color: #7a6b5d;">
          Log in to The Stacks to view full transaction details.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc """
      GDPR data export ready notification.

      The stated expiry is rendered from the real one rather than written into
      the copy: the link is a signature with a deadline on it, and a promise
      that outlives the signature sends people to a dead URL.
  """
  def gdpr_export_ready(download_url, expires_in_seconds \\ 86_400) do
    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">Your data export is ready</h1>
        <p>Your personal data export from The Stacks has been prepared and is ready to download.</p>
        <p>
          <a href="#{download_url}"
             style="background: #2c1810; color: #f5f0e8; padding: 12px 24px; text-decoration: none; display: inline-block;">
            Download export
          </a>
        </p>
        <p style="font-size: 12px; color: #7a6b5d;">
          This link will expire in #{expiry_phrase(expires_in_seconds)}. The copy of your
          data is deleted at the same time — request another export whenever you need one.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc "WishList availability notification."
  def wishlist_availability(book_title) do
    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">A book on your WishList is available</h1>
        <p><em>#{book_title}</em> is now available in The Stacks marketplace.</p>
        <p style="font-size: 12px; color: #7a6b5d;">
          Log in to view the listing. You are receiving this because you have WishList notifications enabled.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc "Group invitation notification."
  def group_invitation(inviter_name, group_name, accept_url) do
    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">You've been invited to a group</h1>
        <p>You've been invited to join <strong>#{group_name}</strong> by <strong>#{inviter_name}</strong>.</p>
        <p>
          <a href="#{accept_url}"
             style="background: #2c1810; color: #f5f0e8; padding: 12px 24px; text-decoration: none; display: inline-block;">
            Accept invitation
          </a>
        </p>
        <p style="font-size: 12px; color: #7a6b5d;">
          You are receiving this because you have group invitation notifications enabled.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc "New offer notification for a seller."
  def new_offer(buyer_name, listing_title, offer_amount_zar, offer_url) do
    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">You have a new offer</h1>
        <p>You have a new offer on <em>#{listing_title}</em> from <strong>#{buyer_name}</strong> for <strong>R#{offer_amount_zar}</strong>.</p>
        <p>
          <a href="#{offer_url}"
             style="background: #2c1810; color: #f5f0e8; padding: 12px 24px; text-decoration: none; display: inline-block;">
            View offer
          </a>
        </p>
        <p style="font-size: 12px; color: #7a6b5d;">
          You are receiving this because you have marketplace notifications enabled.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc "Wishlist availability notification with full listing details."
  def wishlist_available(book_title, author_name, price_zar, seller_name) do
    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">A book on your WishList is available</h1>
        <p><em>#{book_title}</em> by <strong>#{author_name}</strong> is now available for <strong>R#{price_zar}</strong> from <strong>#{seller_name}</strong>.</p>
        <p style="font-size: 12px; color: #7a6b5d;">
          Log in to view the listing. You are receiving this because you have WishList notifications enabled.
        </p>
      </div>
    </body>
    </html>
    """
  end

  @doc "Opt-out / account deletion confirmation."
  def opt_out_confirmation do
    """
    <html>
    <body style="font-family: Georgia, serif; background: #f5f0e8; padding: 40px; color: #2c1810;">
      <div style="max-width: 600px; margin: 0 auto; background: #fff; padding: 40px; border: 1px solid #c9b89a;">
        <h1 style="color: #2c1810; font-size: 24px;">Removal request received</h1>
        <p>Your removal request has been received. Your data will be deleted within 30 days.</p>
        <p>If you have any questions, please contact us at privacy@#{canonical_domain()}.</p>
      </div>
    </body>
    </html>
    """
  end

  defp expiry_phrase(seconds) when seconds < 3600, do: plural(div(seconds, 60), "minute")
  defp expiry_phrase(seconds) when seconds < 172_800, do: plural(div(seconds, 3600), "hour")
  defp expiry_phrase(seconds), do: plural(div(seconds, 86_400), "day")

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(count, unit), do: "#{count} #{unit}s"

  defp canonical_domain do
    Application.get_env(:core, :canonical_domain, "readinginthestacks.com")
  end
end
