defmodule Stacks.Email.Mailer do
  @moduledoc "Swoosh mailer for The Stacks transactional emails."

  use Swoosh.Mailer, otp_app: :core
end
