defmodule Readout.Mailer do
  @moduledoc """
  Outgoing email (Swoosh; SMTP in production). SMTP is optional: without it,
  invitations become copyable links and share links can't require email
  verification.

  Emails are built right away (so callers get the email back) and delivered by
  a background job, so a slow SMTP server never blocks the UI. The job carries
  the email encrypted with the app's secret: sign-in links and codes are never
  readable in the jobs table.
  """
  use Swoosh.Mailer, otp_app: :readout

  @doc "Whether email can be sent (SMTP configured, or the dev/test adapters)."
  def enabled? do
    Application.get_env(:readout, :mail_enabled, false)
  end

  @doc "The From address: `{name, email}`."
  def from, do: Application.get_env(:readout, :mail_from, {"Readout", "readout@localhost"})

  @doc "Queues an email for delivery. Returns `{:ok, email}`."
  def deliver_later(%Swoosh.Email{} = email) do
    {:ok, _job} = email |> Readout.Mailer.DeliverJob.new_job() |> Oban.insert()
    {:ok, email}
  end
end
