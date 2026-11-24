defmodule Readout.Mailer do
  @moduledoc """
  Outgoing email (Swoosh). SMTP is optional: without it, invitations become
  copyable links and share links can't require email verification.
  """
  use Swoosh.Mailer, otp_app: :readout

  @doc "Whether email can be sent (SMTP configured, or the dev/test adapters)."
  def enabled? do
    Application.get_env(:readout, :mail_enabled, false)
  end
end
