defmodule Readout.Accounts.UserNotifier do
  @moduledoc """
  Account emails. Built by `ReadoutWeb.Emails` (translated, HTML and text) and
  delivered in the background by `Readout.Mailer.deliver_later/1`.
  """

  alias Readout.Accounts.User
  alias Readout.Mailer
  alias ReadoutWeb.Emails

  def deliver_update_email_instructions(%User{} = user, url) do
    user.email |> Emails.update_email(locale(user), %{url: url}) |> Mailer.deliver_later()
  end

  def deliver_login_instructions(%User{} = user, url) do
    user.email
    |> Emails.login(locale(user), %{url: url, name: User.display_name(user)})
    |> Mailer.deliver_later()
  end

  def deliver_reset_password_instructions(%User{} = user, url) do
    user.email
    |> Emails.reset_password(locale(user), %{url: url, name: User.display_name(user)})
    |> Mailer.deliver_later()
  end

  def deliver_invitation(invitation, url, %User{} = inviter, details) do
    invitation.email
    |> Emails.invitation(
      locale(inviter),
      Map.merge(details, %{url: url, inviter: User.display_name(inviter)})
    )
    |> Mailer.deliver_later()
  end

  # The user's own language, else the language of the current request.
  defp locale(%User{locale: locale}) when locale in ["en", "es"], do: locale
  defp locale(_user), do: Gettext.get_locale(ReadoutWeb.Gettext)
end
