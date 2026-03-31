defmodule Stacks.Email.Templates do
  @moduledoc "HTML email templates for transactional emails."

  @doc "Confirmation email sent after registration."
  def registration_confirmation(confirmation_url) do
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
          This link expires in 48 hours. If you did not register, you can safely ignore this email.
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

  @doc "Marketplace sale notification — role is :seller or :buyer."
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

  @doc "GDPR data export ready notification."
  def gdpr_export_ready(download_url) do
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
          This link will expire after 7 days.
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
        <p>If you have any questions, please contact us at privacy@thestacks.app.</p>
      </div>
    </body>
    </html>
    """
  end
end
